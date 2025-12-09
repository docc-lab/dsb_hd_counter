package main

import (
	"encoding/json"
	"flag"
	"io/ioutil"
	"os"
	"strconv"
	"time"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/registry"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/profile"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/tracing"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/tune"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

func main() {
	tune.Init()
	log.Logger = zerolog.New(zerolog.ConsoleWriter{Out: os.Stdout, TimeFormat: time.RFC3339}).With().Timestamp().Caller().Logger()

	log.Info().Msg("Reading config...")
	jsonFile, err := os.Open("config.json")
	if err != nil {
		log.Error().Msgf("Got error while reading config: %v", err)
	}

	defer jsonFile.Close()

	byteValue, _ := ioutil.ReadAll(jsonFile)

	var result map[string]string
	json.Unmarshal([]byte(byteValue), &result)

	log.Info().Msg("Initializing DB connection...")
	mongoClient, mongoClose := initializeDatabase(result["ProfileMongoAddress"])
	defer mongoClose()

	log.Info().Msgf("Read profile memcashed address: %v", result["ProfileMemcAddress"])
	log.Info().Msg("Initializing Memcashed client...")
	memcClient := tune.NewMemCClient2(result["ProfileMemcAddress"])
	log.Info().Msg("Success")

	servPort, _ := strconv.Atoi(result["ProfilePort"])
	servIP := result["ProfileIP"]

	var (
		jaegerAddr = flag.String("jaegeraddr", result["jaegerAddress"], "Jaeger address")
		consulAddr = flag.String("consuladdr", result["consulAddress"], "Consul address")
	)
	flag.Parse()

	log.Info().Msgf("Initializing jaeger agent [service name: %v | host: %v]...", "profile", *jaegerAddr)
	tracer, err := tracing.Init("profile", *jaegerAddr)
	if err != nil {
		log.Panic().Msgf("Got error while initializing jaeger agent: %v", err)
	}
	log.Info().Msg("Jaeger agent initialized")

	log.Info().Msgf("Initializing consul agent [host: %v]...", *consulAddr)
	registry, err := registry.NewClient(*consulAddr)
	if err != nil {
		log.Panic().Msgf("Got error while initializing consul agent: %v", err)
	}
	log.Info().Msg("Consul agent initialized")

	// Check if windowed sampling is enabled
	enableWindowed := os.Getenv("ENABLE_WINDOWED_SAMPLING")
	if enableWindowed == "true" {
		// Use windowed sampling mode with perf counters
		iterationID, _ := strconv.Atoi(os.Getenv("ITERATION_ID"))
		if iterationID == 0 {
			iterationID = 1
		}

		log.Info().
			Str("service", "profile").
			Int("iteration", iterationID).
			Msg("Starting profile service with windowed sampling")

		// Setup continuous windowed sampling (runs for 24h, writes periodically)
		sampler, timingAgg, _, err := perf.SetupContinuousSampling("profile", iterationID)
		if err != nil {
			log.Fatal().Err(err).Msg("Failed to setup continuous sampling")
		}

		// Cleanup handlers (will run when pod terminates)
		defer func() {
			log.Info().Msg("Pod terminating, stopping sampler")
			runData, err := sampler.StopRun()
			if err != nil {
				log.Error().Err(err).Msg("Error stopping sampler")
			} else if runData != nil {
				log.Info().
					Int("sample_count", runData.SampleCount).
					Int("total_requests", runData.Aggregates.TotalRequests).
					Msg("Sampling stopped on termination")
			}
			timingAgg.Stop()
		}()

		srv := &profile.Server{
			Port:             servPort,
			IpAddr:           servIP,
			Tracer:           tracer,
			Registry:         registry,
			MongoClient:      mongoClient,
			MemcClient:       memcClient,
			TimingAggregator: timingAgg,
		}

		log.Info().Msg("Starting server with continuous windowed sampling...")

		// Start server (blocks until shutdown)
		if err := srv.Run(); err != nil {
			log.Error().Err(err).Msg("Server failed")
			os.Exit(1)
		}
	} else {
		// Standard mode without windowed sampling
		srv := &profile.Server{
			Port:        servPort,
			IpAddr:      servIP,
			Tracer:      tracer,
			Registry:    registry,
			MongoClient: mongoClient,
			MemcClient:  memcClient,
		}

		log.Info().Msg("Starting server...")
		if err := srv.Run(); err != nil {
			log.Error().Err(err).Msg("Server failed")
			os.Exit(1)
		}
	}
}
