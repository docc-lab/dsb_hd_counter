package profile

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/bradfitz/gomemcache/memcache"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
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
	defaultCacheSize   = 80    // Load all 80 hotels into L1 cache (original hotel count)
	                           // With 64KB per hotel: 80 × 64 KB = 5.12 MB total memory footprint
	                           // Bucket size: 8 hotels × 64KB = 512 KB per bucket
	                           // Typical request: ~5 IDs → ~5 buckets × 512 KB = 2.56 MB > L2 (1.25 MB) ✓
	defaultRepeatCount = 4     // Times to repeat lookup of requested IDs (keeps data in CPU L3)
	                           // For N requested IDs: N × 4 lookups (all integrated into business logic)
)

// Server implements the profile service
type Server struct {
	pb.UnimplementedProfileServer

	uuid string

	// L1 in-memory cache layer (for cache contention experiments)
	// Provides fast O(1) lookups while creating controlled memory working set
	// Multi-tier: L1 (in-memory) → L2 (memcached) → L3 (MongoDB)
	hotelCache   map[string]*CachedHotel // Maps hotel ID → Hotel with padding
	cacheSize    int                     // Max hotels in L1 cache (working set size)
	repeatAccess int                     // Times to repeat each lookup (keeps data in CPU L3)

	Tracer           opentracing.Tracer
	Port             int
	IpAddr           string
	MongoClient      *mongo.Client
	Registry         *registry.Client
	MemcClient       *memcache.Client
	TimingAggregator interceptor.TimingAggregator // Optional: for windowed sampling
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

	// Setup timing interceptor
	var timingInterceptor grpc.UnaryServerInterceptor

	if s.TimingAggregator != nil {
		// Windowed sampling mode - use provided aggregator
		timingInterceptor = interceptor.TimingServerInterceptorWithAggregator(s.TimingAggregator, name)
		log.Info().Str("service", name).Msg("Timing interceptor ENABLED (windowed sampling with perf counters)")
	} else {
		// Standard mode - check if timing is enabled
		enableTiming := os.Getenv("ENABLE_TIMING") == "true"
		if enableTiming {
			// Create basic ring buffer aggregator for timing only
			timingConfig := interceptor.TimingConfig{
				EnableTiming: true,
				ServiceName:  name,
			}
			basicAggregator := interceptor.NewRingBufferTimingAggregator(timingConfig)
			timingInterceptor = interceptor.TimingServerInterceptorWithAggregator(basicAggregator, name)
			log.Info().Str("service", name).Msg("Timing interceptor ENABLED (basic mode, no perf counters)")
		} else {
			// No timing - use tracing only
			timingInterceptor = nil
			log.Info().Str("service", name).Msg("Timing interceptor DISABLED")
		}
	}

	// Build server options
	opts := []grpc.ServerOption{
		grpc.KeepaliveParams(keepalive.ServerParameters{
			Timeout: 120 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			PermitWithoutStream: true,
		}),
	}

	// Add interceptors (tracing + timing if enabled)
	if timingInterceptor != nil {
		opts = append(opts, grpc.UnaryInterceptor(
			interceptor.ChainUnaryServerInterceptors(
				otgrpc.OpenTracingServerInterceptor(s.Tracer),
				timingInterceptor,
			),
		))
	} else {
		opts = append(opts, grpc.UnaryInterceptor(
			otgrpc.OpenTracingServerInterceptor(s.Tracer),
		))
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

	res := new(pb.Result)
	hotels := make([]*pb.Hotel, 0)
	
	// Deduplicate requested IDs
	hotelIds := make([]string, 0)
	profileMap := make(map[string]struct{})
	for _, hotelId := range req.HotelIds {
		if _, exists := profileMap[hotelId]; !exists {
			hotelIds = append(hotelIds, hotelId)
			profileMap[hotelId] = struct{}{}
		}
	}

	// ========================================
	// L1 CACHE LAYER (Balanced Random Access for Cache Contention)
	// ========================================
	// Balanced approach for cache pressure without excessive overhead:
	// 1. Access random hotels from cache (defeats spatial locality)
	// 2. Sample padding with random pattern (defeats prefetcher, reduces overhead)
	// 3. Multiple repetitions (keeps data warm in CPU L3)
	// 4. Then serve actual business logic
	// Total: 80 hotels × 64 sampled cache lines × 4 repeats = 20,480 accesses (~3-5ms overhead)
	l1Hits := make(map[string]*pb.Hotel)
	
	if s.hotelCache != nil && len(s.hotelCache) > 0 {
		// Build list of all hotel IDs for random access
		allCacheIDs := make([]string, 0, len(s.hotelCache))
		for id := range s.hotelCache {
			allCacheIDs = append(allCacheIDs, id)
		}
		
		// Determine how many hotels to access (default: all 80)
		randomAccessCount := len(allCacheIDs)
		if s.cacheSize > 0 && s.cacheSize < randomAccessCount {
			randomAccessCount = s.cacheSize
		}
		
		// Sample padding at reduced rate to avoid excessive overhead
		// Access every Nth cache line instead of all 1024
		const paddingSampleRate = 16  // Access 1024/16 = 64 cache lines per hotel
		const sampledCacheLines = 64
		randomPaddingIndices := make([]int, sampledCacheLines)
		for i := 0; i < sampledCacheLines; i++ {
			randomPaddingIndices[i] = i * 64 * paddingSampleRate  // 0, 1024, 2048, ...
		}
		rand.Shuffle(len(randomPaddingIndices), func(i, j int) {
			randomPaddingIndices[i], randomPaddingIndices[j] = randomPaddingIndices[j], randomPaddingIndices[i]
		})
		
		// Multi-round random access
		sum := 0
		for round := 0; round < s.repeatAccess; round++ {
			// Shuffle hotel order each round for maximum randomness
			rand.Shuffle(len(allCacheIDs), func(i, j int) {
				allCacheIDs[i], allCacheIDs[j] = allCacheIDs[j], allCacheIDs[i]
			})
			
			// Access random subset of hotels
			for i := 0; i < randomAccessCount; i++ {
				hotelId := allCacheIDs[i]
				cached := s.hotelCache[hotelId]
				
				// Touch hotel fields
				_ = cached.Hotel.Id
				_ = cached.Hotel.Name
				if cached.Hotel.Address != nil {
					_ = cached.Hotel.Address.Lat + cached.Hotel.Address.Lon
				}
				
				// Random padding access (defeats prefetcher)
				for _, idx := range randomPaddingIndices {
					sum += int(cached.CachePadding[idx])
				}
			}
		}
		
		// Prevent compiler optimization
		if sum > 0x7FFFFFFF {
			log.Trace().Msgf("Cache work: %d", sum)
		}
		
		// Now serve actual business logic - lookup requested IDs
		for _, hotelId := range hotelIds {
			if cached := s.hotelCache[hotelId]; cached != nil {
				l1Hits[hotelId] = cached.Hotel
			}
		}
		
		if len(l1Hits) > 0 {
			log.Trace().Msgf("L1 cache: %d hits (random access: %d hotels × %d repeats × 64 sampled cache lines)", 
				len(l1Hits), randomAccessCount, s.repeatAccess)
		}
	}
	
	// Collect L1 hits
	for _, hotel := range l1Hits {
		hotels = append(hotels, hotel)
		delete(profileMap, hotel.Id)
	}
	// ========================================
	// END L1 CACHE
	// ========================================

	// L1 misses - check L2 (memcached) and L3 (MongoDB)
	if len(profileMap) == 0 {
		// All hits from L1 cache, return immediately
		res.Hotels = hotels
		
		if span := opentracing.SpanFromContext(ctx); span != nil {
			counterResults := C.GoString(C.perf_stop(C.int(cHandles.leader_fd),C.int(cHandles.instructions_fd),C.int(cHandles.l1_misses_fd)))
			span.SetTag("Machine Counter Readings", counterResults)
		}
		
		return res, nil
	}

	// Build list of IDs that missed L1
	missedIds := make([]string, 0, len(profileMap))
	for hotelId := range profileMap {
		missedIds = append(missedIds, hotelId)
	}

	// L2: Check memcached for L1 misses
	memSpan, _ := opentracing.StartSpanFromContext(ctx, "memcached_get_profile")
	memSpan.SetTag("span.kind", "client")
	resMap, err := s.MemcClient.GetMulti(missedIds)
	memSpan.Finish()
	
	var wg sync.WaitGroup
	var mutex sync.Mutex

	if err != nil && err != memcache.ErrCacheMiss {
		log.Error().Msgf("Tried to get hotelIds [%v], but got memcached error = %s; falling back to mongo", hotelIds, err)
		resMap = nil
	}
	{
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
	// With 65472 bytes of padding, each cached hotel = 65536 bytes (64 KB)
	// Bucket-aware design: 8 hotels per bucket × 64 KB = 512 KB per bucket
	// Accessing ~5 IDs → ~5 buckets × 512 KB = 2.56 MB > L2 (1.25 MB) ✓
	CachePadding [65472]byte
}

// loadHotelCache loads hotels from MongoDB into in-memory L1 cache
// Creates working set > L2 size for cache contention experiments
func (s *Server) loadHotelCache() error {
	log.Info().Msg("Loading hotel profiles into in-memory L1 cache...")
	
	collection := s.MongoClient.Database("profile-db").Collection("hotels")
	
	// Load up to cacheSize hotels (typically 10,000)
	// This creates the working set size for cache contention
	findOpts := options.Find().SetLimit(int64(s.cacheSize))
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

	workingSetMB := float64(len(s.hotelCache)) * 65536 / 1024 / 1024
	log.Info().Msgf("Loaded %d hotels into L1 cache (total working set: ~%.1f MB)", 
		len(s.hotelCache), workingSetMB)
	log.Info().Msgf("Per request: ~5 IDs → ~5 buckets × 8 hotels × 64KB = ~2.56 MB > L2 (1.25 MB)")
	log.Info().Msgf("Cache configuration: repeat=%d times per lookup (keeps data warm in CPU L3)", 
		s.repeatAccess)
	
	return nil
}
