package recommendation

import (
	"context"
	"fmt"
	"math"
	"net"
	"os"
	"time"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/registry"
	pb "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/recommendation/proto"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/tls"
	"github.com/google/uuid"
	"github.com/grpc-ecosystem/grpc-opentracing/go/otgrpc"
	"github.com/hailocab/go-geoindex"
	"github.com/opentracing/opentracing-go"
	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
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

const name = "srv-recommendation"

// Server implements the recommendation service
type Server struct {
	pb.UnimplementedRecommendationServer

	hotels map[string]Hotel
	uuid   string

	Tracer           opentracing.Tracer
	Port             int
	IpAddr           string
	MongoClient      *mongo.Client
	Registry         *registry.Client
	TimingAggregator interceptor.TimingAggregator // Optional: for windowed sampling
}

// Run starts the server
func (s *Server) Run() error {
	opentracing.SetGlobalTracer(s.Tracer)

	if s.Port == 0 {
		return fmt.Errorf("server port must be set")
	}

	if s.hotels == nil {
		s.hotels = loadRecommendations(s.MongoClient)
	}

	s.uuid = uuid.New().String()

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

	pb.RegisterRecommendationServer(srv, s)

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", s.Port))
	if err != nil {
		log.Fatal().Msgf("failed to listen: %v", err)
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

// GiveRecommendation returns recommendations within a given requirement.
func (s *Server) GetRecommendations(ctx context.Context, req *pb.Request) (*pb.Result, error) {

	var cHandles C.struct_perf_handles
	if span := opentracing.SpanFromContext(ctx); span != nil {
		cHandles = C.perf_start()
	}
	
	res := new(pb.Result)
	log.Trace().Msgf("GetRecommendations")
	require := req.Require
	if require == "dis" {
		p1 := &geoindex.GeoPoint{
			Pid:  "",
			Plat: req.Lat,
			Plon: req.Lon,
		}
		min := math.MaxFloat64
		for _, hotel := range s.hotels {
			tmp := float64(geoindex.Distance(p1, &geoindex.GeoPoint{
				Pid:  "",
				Plat: hotel.HLat,
				Plon: hotel.HLon,
			})) / 1000
			if tmp < min {
				min = tmp
			}
		}
		for _, hotel := range s.hotels {
			tmp := float64(geoindex.Distance(p1, &geoindex.GeoPoint{
				Pid:  "",
				Plat: hotel.HLat,
				Plon: hotel.HLon,
			})) / 1000
			if tmp == min {
				res.HotelIds = append(res.HotelIds, hotel.HId)
			}
		}
	} else if require == "rate" {
		max := 0.0
		for _, hotel := range s.hotels {
			if hotel.HRate > max {
				max = hotel.HRate
			}
		}
		for _, hotel := range s.hotels {
			if hotel.HRate == max {
				res.HotelIds = append(res.HotelIds, hotel.HId)
			}
		}
	} else if require == "price" {
		min := math.MaxFloat64
		for _, hotel := range s.hotels {
			if hotel.HPrice < min {
				min = hotel.HPrice
			}
		}
		for _, hotel := range s.hotels {
			if hotel.HPrice == min {
				res.HotelIds = append(res.HotelIds, hotel.HId)
			}
		}
	} else {
		log.Warn().Msgf("Wrong require parameter: %v", require)
	}
	
	if span := opentracing.SpanFromContext(ctx); span != nil {
		counterResults := C.GoString(C.perf_stop(C.int(cHandles.leader_fd),C.int(cHandles.instructions_fd),C.int(cHandles.l1_misses_fd)))
		span.SetTag("Machine Counter Readings", counterResults)
	}
 
	return res, nil
}

// loadRecommendations loads hotel recommendations from mongodb.
func loadRecommendations(client *mongo.Client) map[string]Hotel {
	collection := client.Database("recommendation-db").Collection("recommendation")
	curr, err := collection.Find(context.TODO(), bson.D{})
	if err != nil {
		log.Error().Msgf("Failed get hotels data: ", err)
	}

	var hotels []Hotel
	curr.All(context.TODO(), &hotels)
	if err != nil {
		log.Error().Msgf("Failed get hotels data: ", err)
	}

	profiles := make(map[string]Hotel)
	for _, hotel := range hotels {
		profiles[hotel.HId] = hotel
	}

	return profiles
}

type Hotel struct {
	HId    string  `bson:"hotelId"`
	HLat   float64 `bson:"lat"`
	HLon   float64 `bson:"lon"`
	HRate  float64 `bson:"rate"`
	HPrice float64 `bson:"price"`
	
	// Cache contention experiment: padding to increase memory footprint
	// With 448 bytes of padding, each hotel = ~512 bytes in memory (power of 2)
	// 20,000 hotels × 512 bytes = 10.24 MB working set (memory-bound)
	CachePadding [448]byte `bson:"-"`
}
