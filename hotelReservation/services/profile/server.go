package profile

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/bradfitz/gomemcache/memcache"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/registry"
	pb "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/profile/proto"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/tls"
	"github.com/google/uuid"
	"github.com/grpc-ecosystem/grpc-opentracing/go/otgrpc"
	"github.com/opentracing/opentracing-go"
	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"google.golang.org/grpc"
	"google.golang.org/grpc/keepalive"
)

/*
#cgo CFLAGS: -I../perf
#cgo LDFLAGS: -L../perf -lperf_api
#include "../perf/perf_api.h"
*/
import "C"

type PerfHandles struct {
    LeaderFD       int
    InstructionsFD int
    L1MissesFD     int
}

const name = "srv-profile"

// Cache contention experiment configuration
const (
	maxReturnedHotelID = 80    // Only return IDs 1-80 to avoid breaking downstream services
	defaultCacheSize   = 5000  // Default working set to access per request (configurable)
	                           // 5000 hotels × 512 bytes = 2.56 MB > L2 per-core (1.25 MB)
	defaultRepeatCount = 4     // Number of times to access working set
	                           // Total accesses: 5000 × 4 = 20,000 accesses per request
)

// Server implements the profile service
type Server struct {
	pb.UnimplementedProfileServer

	uuid string

	// In-memory cache for cache contention experiments
	// Maps hotel ID -> Hotel with padding for controlled working set size
	hotelCache map[string]*CachedHotel
	cacheSize  int
	repeatAccess int

	Tracer      opentracing.Tracer
	Port        int
	IpAddr      string
	MongoClient *mongo.Client
	Registry    *registry.Client
	MemcClient  *memcache.Client
}

// Run starts the server
func (s *Server) Run() error {
	opentracing.SetGlobalTracer(s.Tracer)

	if s.Port == 0 {
		return fmt.Errorf("server port must be set")
	}

	s.uuid = uuid.New().String()
	
	// Configure in-memory cache for cache contention experiments
	s.cacheSize = defaultCacheSize
	if cacheSizeStr := os.Getenv("PROFILE_CACHE_SIZE"); cacheSizeStr != "" {
		if size, err := strconv.Atoi(cacheSizeStr); err == nil && size > 0 {
			s.cacheSize = size
		}
	}
	
	s.repeatAccess = defaultRepeatCount
	if repeatStr := os.Getenv("PROFILE_CACHE_REPEAT"); repeatStr != "" {
		if repeat, err := strconv.Atoi(repeatStr); err == nil && repeat > 0 {
			s.repeatAccess = repeat
		}
	}
	
	// Load hotels into in-memory cache
	if err := s.loadHotelCache(); err != nil {
		return fmt.Errorf("failed to load hotel cache: %v", err)
	}

	log.Trace().Msgf("in run s.IpAddr = %s, port = %d", s.IpAddr, s.Port)

	opts := []grpc.ServerOption{
		grpc.KeepaliveParams(keepalive.ServerParameters{
			Timeout: 120 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			PermitWithoutStream: true,
		}),
		grpc.UnaryInterceptor(
			otgrpc.OpenTracingServerInterceptor(s.Tracer),
		),
	}

	if tlsopt := tls.GetServerOpt(); tlsopt != nil {
		opts = append(opts, tlsopt)
	}

	srv := grpc.NewServer(opts...)

	pb.RegisterProfileServer(srv, s)

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", s.Port))
	if err != nil {
		log.Fatal().Msgf("failed to configure listener: %v", err)
	}

	err = s.Registry.Register(name, s.uuid, s.IpAddr, s.Port)
	if err != nil {
		return fmt.Errorf("failed register: %v", err)
	}
	log.Info().Msg("Successfully registered in consul")

	return srv.Serve(lis)
}

// Shutdown cleans up any processes
func (s *Server) Shutdown() {
	s.Registry.Deregister(s.uuid)
}

// GetProfiles returns hotel profiles for requested IDs
func (s *Server) GetProfiles(ctx context.Context, req *pb.Request) (*pb.Result, error) {
	log.Trace().Msgf("In GetProfiles")

	var cHandles C.struct_perf_handles
	if span := opentracing.SpanFromContext(ctx); span != nil {
		cHandles = C.perf_start()
	}

	// ========================================
	// CACHE AMPLIFICATION WORK (Cache Contention Experiment)
	// ========================================
	// Access working set multiple times to create cache pressure
	// - Random map iteration ensures poor cache locality
	// - Multiple accesses keep data warm in L3 (prevents early eviction)
	// - Working set > L2 size guarantees L3 usage on non-inclusive caches
	// - Minimal CPU work (just touching data, no computation)
	if s.hotelCache != nil && len(s.hotelCache) > 0 {
		accessCount := 0
		targetAccesses := s.cacheSize
		if targetAccesses > len(s.hotelCache) {
			targetAccesses = len(s.hotelCache)
		}
		
		for round := 0; round < s.repeatAccess; round++ {
			accessCount = 0
			for _, cached := range s.hotelCache {
				// Touch the hotel data to load cache lines
				// Access actual fields to prevent compiler optimization
				_ = cached.Hotel.Id
				_ = cached.Hotel.Name
				if cached.Hotel.Address != nil {
					_ = cached.Hotel.Address.Lat + cached.Hotel.Address.Lon
				}
				
				accessCount++
				if accessCount >= targetAccesses {
					break
				}
			}
		}
		log.Trace().Msgf("Cache amplification: accessed %d hotels × %d times = %d total accesses", 
			accessCount, s.repeatAccess, accessCount * s.repeatAccess)
	}
	// ========================================
	// END CACHE AMPLIFICATION
	// ========================================

	var wg sync.WaitGroup
	var mutex sync.Mutex

	// one hotel should only have one profile
	hotelIds := make([]string, 0)
	profileMap := make(map[string]struct{})
	for _, hotelId := range req.HotelIds {
		hotelIds = append(hotelIds, hotelId)
		profileMap[hotelId] = struct{}{}
	}


	memSpan, _ := opentracing.StartSpanFromContext(ctx, "memcached_get_profile")
	memSpan.SetTag("span.kind", "client")
	resMap, err := s.MemcClient.GetMulti(hotelIds)
	memSpan.Finish()

	res := new(pb.Result)
	hotels := make([]*pb.Hotel, 0)

	if err != nil && err != memcache.ErrCacheMiss {
		log.Panic().Msgf("Tried to get hotelIds [%v], but got memmcached error = %s", hotelIds, err)
	} else {
		for hotelId, item := range resMap {
			profileStr := string(item.Value)
			log.Trace().Msgf("memc hit with %v", profileStr)

			hotelProf := new(pb.Hotel)
			json.Unmarshal(item.Value, hotelProf)
			hotels = append(hotels, hotelProf)
			delete(profileMap, hotelId)
		}

		// Cap the number of goroutines
		maxGoroutines := 50
		actualGoroutines := len(profileMap)
		if actualGoroutines > maxGoroutines {
			actualGoroutines = maxGoroutines
		}
		
		wg.Add(actualGoroutines)
		hotelIds := make([]string, 0, len(profileMap))
		for hotelId := range profileMap {
			hotelIds = append(hotelIds, hotelId)
		}
		
		// Distribute work among limited goroutines
		for i := 0; i < actualGoroutines; i++ {
			go func(workerID int) {
				defer wg.Done()
				// Each worker processes a subset of hotels
				for j := workerID; j < len(hotelIds); j += actualGoroutines {
					hotelId := hotelIds[j]
				var hotelProf *pb.Hotel

				collection := s.MongoClient.Database("profile-db").Collection("hotels")

				mongoSpan, _ := opentracing.StartSpanFromContext(ctx, "mongo_profile")
				mongoSpan.SetTag("span.kind", "client")
				err := collection.FindOne(context.TODO(), bson.D{{"id", hotelId}}).Decode(&hotelProf)
				mongoSpan.Finish()

				if err != nil {
					log.Error().Msgf("Failed get hotels data: ", err)
				}

				mutex.Lock()
				hotels = append(hotels, hotelProf)
				mutex.Unlock()

				profJson, err := json.Marshal(hotelProf)
				if err != nil {
					log.Error().Msgf("Failed to marshal hotel [id: %v] with err:", hotelProf.Id, err)
				}
				memcStr := string(profJson)

				// write to memcached
				go s.MemcClient.Set(&memcache.Item{Key: hotelId, Value: []byte(memcStr)})
				}
			}(i)
		}
	}
	wg.Wait()

	if span := opentracing.SpanFromContext(ctx); span != nil {
		counterResults := C.GoString(C.perf_stop(C.int(cHandles.leader_fd),C.int(cHandles.instructions_fd),C.int(cHandles.l1_misses_fd)))
		span.SetTag("Machine Counter Readings", counterResults)
	}
	
	//counterResults := C.GoString(C.perf_stop())
	//counterSpan.SetTag("Machine Counter Readings", counterResults)
	//counterSpan.Finish()

	res.Hotels = hotels
	log.Trace().Msgf("In GetProfiles after getting resp")
 
	return res, nil
}

// CachedHotel wraps a Hotel with padding for cache contention experiments
type CachedHotel struct {
	Hotel *pb.Hotel
	// Padding to increase memory footprint for cache contention experiments
	// With 448 bytes of padding, each cached hotel = ~512 bytes
	// 20,000 hotels × 512 bytes = 10.24 MB working set (> L2 per-core size of 1.25 MB)
	CachePadding [448]byte
}

// loadHotelCache loads hotels from MongoDB into in-memory cache
// Loads enough hotels to create working set > L2 size, but not all 20K
func (s *Server) loadHotelCache() error {
	log.Info().Msg("Loading hotel profiles into in-memory cache for cache contention experiments...")
	
	// Determine how many hotels to load
	// Load 2x the access size to allow for variation but avoid loading all 20K
	maxToLoad := s.cacheSize * 2
	if maxToLoad > 20000 {
		maxToLoad = 20000
	}
	
	collection := s.MongoClient.Database("profile-db").Collection("hotels")
	
	// Use find with limit to avoid loading all hotels
	findOpts := options.Find().SetLimit(int64(maxToLoad))
	curr, err := collection.Find(context.TODO(), bson.D{}, findOpts)
	if err != nil {
		return fmt.Errorf("failed to load hotels: %v", err)
	}

	var hotels []*pb.Hotel
	if err := curr.All(context.TODO(), &hotels); err != nil {
		return fmt.Errorf("failed to decode hotels: %v", err)
	}

	s.hotelCache = make(map[string]*CachedHotel, len(hotels))
	for _, hotel := range hotels {
		s.hotelCache[hotel.Id] = &CachedHotel{Hotel: hotel}
	}

	workingSetMB := float64(len(s.hotelCache)) * 512 / 1024 / 1024
	log.Info().Msgf("Loaded %d hotels into cache (working set: ~%.1f MB, will access %d per request)", 
		len(s.hotelCache), workingSetMB, s.cacheSize)
	
	return nil
}
