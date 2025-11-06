package search

import (
	"fmt"
	"net"
	"os"
	"time"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/dialer"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/registry"
	geo "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/geo/proto"
	rate "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/rate/proto"
	pb "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/search/proto"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/tls"
	"github.com/google/uuid"
	_ "github.com/mbobakov/grpc-consul-resolver"
	opentracing "github.com/opentracing/opentracing-go"
	"github.com/rs/zerolog/log"
	context "golang.org/x/net/context"
	"google.golang.org/grpc"
	"google.golang.org/grpc/keepalive"
)

// Removed CGO imports and PerfHandles - now using integrated timing+perf interceptor

const name = "srv-search"

// Server implments the search service
type Server struct {
	pb.UnimplementedSearchServer

	geoClient  geo.GeoClient
	rateClient rate.RateClient
	uuid       string

	Tracer     opentracing.Tracer
	Port       int
	IpAddr     string
	ConsulAddr string
	KnativeDns string
	Registry   *registry.Client
}

// Run starts the server
func (s *Server) Run() error {
	opentracing.SetGlobalTracer(s.Tracer)

	if s.Port == 0 {
		return fmt.Errorf("server port must be set")
	}

	s.uuid = uuid.New().String()

	// Configure timing + perf interceptor (can be controlled via environment variables)
	enableTiming := os.Getenv("ENABLE_TIMING") == "true"
	enablePerf := os.Getenv("ENABLE_PERF") == "true"
	perfEvents := os.Getenv("PERF_EVENTS")
	if perfEvents == "" {
		perfEvents = "basic" // Default to basic set
	}

	statsFile := os.Getenv("STATS_FILE")
	if statsFile == "" {
		statsFile = "timing_stats_search.json"
	}

	timingConfig := interceptor.TimingConfig{
		EnableTiming: enableTiming,
		EnablePerf:   enablePerf,
		PerfEvents:   perfEvents,
		ServiceName:  name,
		StatsFile:    statsFile,
	}

	serverOpts := interceptor.ServerOptions{
		TimingConfig: timingConfig,
		Tracer:       s.Tracer,
	}

	opts := []grpc.ServerOption{
		grpc.KeepaliveParams(keepalive.ServerParameters{
			Timeout: 120 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			PermitWithoutStream: true,
		}),
		serverOpts.GetServerInterceptor(), // This includes tracing, timing, and perf
	}

	if enableTiming {
		log.Info().Str("service", name).Str("stats_file", statsFile).Msg("Timing interceptor ENABLED")
	} else {
		log.Info().Str("service", name).Msg("Timing interceptor DISABLED")
	}

	if enablePerf {
		log.Info().Str("service", name).Str("perf_events", perfEvents).Msg("Perf interceptor ENABLED")
	} else {
		log.Info().Str("service", name).Msg("Perf interceptor DISABLED")
	}

	if tlsopt := tls.GetServerOpt(); tlsopt != nil {
		opts = append(opts, tlsopt)
	}

	srv := grpc.NewServer(opts...)
	pb.RegisterSearchServer(srv, s)

	// init grpc clients
	if err := s.initGeoClient("srv-geo"); err != nil {
		return err
	}
	if err := s.initRateClient("srv-rate"); err != nil {
		return err
	}

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

func (s *Server) initGeoClient(name string) error {
	conn, err := s.getGprcConn(name)
	if err != nil {
		return fmt.Errorf("dialer error: %v", err)
	}
	s.geoClient = geo.NewGeoClient(conn)
	return nil
}

func (s *Server) initRateClient(name string) error {
	conn, err := s.getGprcConn(name)
	if err != nil {
		return fmt.Errorf("dialer error: %v", err)
	}
	s.rateClient = rate.NewRateClient(conn)
	return nil
}

func (s *Server) getGprcConn(name string) (*grpc.ClientConn, error) {
	// Check if timing is enabled to decide which interceptor to use
	enableTiming := os.Getenv("ENABLE_TIMING") == "true"
	
	if s.KnativeDns != "" {
		if enableTiming {
			return dialer.Dial(
				fmt.Sprintf("consul://%s/%s.%s", s.ConsulAddr, name, s.KnativeDns),
				dialer.WithTracerAndTiming(s.Tracer))
		} else {
			return dialer.Dial(
				fmt.Sprintf("consul://%s/%s.%s", s.ConsulAddr, name, s.KnativeDns),
				dialer.WithTracer(s.Tracer))
		}
	} else {
		if enableTiming {
			return dialer.Dial(
				fmt.Sprintf("consul://%s/%s", s.ConsulAddr, name),
				dialer.WithTracerAndTiming(s.Tracer),
				dialer.WithBalancer(s.Registry.Client),
			)
		} else {
			return dialer.Dial(
				fmt.Sprintf("consul://%s/%s", s.ConsulAddr, name),
				dialer.WithTracer(s.Tracer),
				dialer.WithBalancer(s.Registry.Client),
			)
		}
	}
}

// Nearby returns ids of nearby hotels ordered by ranking algo
func (s *Server) Nearby(ctx context.Context, req *pb.NearbyRequest) (*pb.SearchResult, error) {
	// find nearby hotels
	log.Trace().Msg("in Search Nearby")

	log.Trace().Msgf("nearby lat = %f", req.Lat)
	log.Trace().Msgf("nearby lon = %f", req.Lon)

	nearby, err := s.geoClient.Nearby(ctx, &geo.Request{
		Lat: req.Lat,
		Lon: req.Lon,
	})
	if err != nil {
		return nil, err
	}

	for _, hid := range nearby.HotelIds {
		log.Trace().Msgf("get Nearby hotelId = %s", hid)
	}

	// find rates for hotels
	rates, err := s.rateClient.GetRates(ctx, &rate.Request{
		HotelIds: nearby.HotelIds,
		InDate:   req.InDate,
		OutDate:  req.OutDate,
	})
	if err != nil {
		return nil, err
	}

	// TODO(hw): add simple ranking algo to order hotel ids:
	// * geo distance
	// * price (best discount?)
	// * reviews

	// build the response
	res := new(pb.SearchResult)
	for _, ratePlan := range rates.RatePlans {
		log.Trace().Msgf("get RatePlan HotelId = %s, Code = %s", ratePlan.HotelId, ratePlan.Code)
		res.HotelIds = append(res.HotelIds, ratePlan.HotelId)
	}

	return res, nil
}
