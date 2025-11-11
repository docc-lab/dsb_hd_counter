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
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/search"
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

	servPort, _ := strconv.Atoi(result["SearchPort"])
	servIP := result["SearchIP"]
	knativeDNS := result["KnativeDomainName"]

	var (
		jaegerAddr = flag.String("jaegerAddr", result["jaegerAddress"], "Jaeger address")
		consulAddr = flag.String("consulAddr", result["consulAddress"], "Consul address")
	)
	flag.Parse()

	log.Info().Msgf("Initializing jaeger agent [service name: %v | host: %v]...", "search", *jaegerAddr)
	tracer, err := tracing.Init("search", *jaegerAddr)
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
			Str("service", "search").
			Int("iteration", iterationID).
			Msg("Starting search service with windowed sampling")

		// Setup continuous windowed sampling (runs indefinitely)
		// Note: sampling continues for entire pod lifetime, data-collector extracts relevant time windows
		sampler, timingAgg, _, err := perf.SetupContinuousSampling("search", iterationID)
		if err != nil {
			log.Fatal().Err(err).Msg("Failed to setup continuous sampling")
		}
		defer timingAgg.Stop()
		defer sampler.Stop()
		
		srv := &search.Server{
			Tracer:           tracer,
			Port:             servPort,
			IpAddr:           servIP,
			ConsulAddr:       *consulAddr,
			KnativeDns:       knativeDNS,
			Registry:         registry,
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
		srv := &search.Server{
			Tracer:     tracer,
			Port:       servPort,
			IpAddr:     servIP,
			ConsulAddr: *consulAddr,
			KnativeDns: knativeDNS,
			Registry:   registry,
		}

		log.Info().Msg("Starting server...")
		if err := srv.Run(); err != nil {
			log.Error().Err(err).Msg("Server failed")
			os.Exit(1)
		}
	}
}
