package main

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// Default number of hotels - can be overridden with HOTEL_COUNT env var
// Using padding to control working set size without increasing iteration complexity
// Target: >10MB for memory-bound behavior (per Mark Hempstead's guidance)
// 20000 hotels × ~512 bytes (with padding) ≈ 10.24 MB working set
// Random map iteration creates cache misses even with working set < L3 size
const defaultHotelCount = 20000

type Hotel struct {
	HId    string  `bson:"hotelId"`
	HLat   float64 `bson:"lat"`
	HLon   float64 `bson:"lon"`
	HRate  float64 `bson:"rate"`
	HPrice float64 `bson:"price"`
	
	// Cache contention experiment: padding to increase memory footprint
	// This padding is NOT stored in MongoDB (bson:"-")
	// With 448 bytes of padding, each hotel struct = ~512 bytes total (power of 2)
	// 20,000 hotels × 512 bytes = 10.24 MB working set (memory-bound)
	CachePadding [448]byte `bson:"-"`
}

func initializeDatabase(url string) (*mongo.Client, func()) {
	uri := fmt.Sprintf("mongodb://%s", url)
	log.Info().Msgf("Attempting connection to %v", uri)

	opts := options.Client().ApplyURI(uri)
	client, err := mongo.Connect(context.TODO(), opts)
	if err != nil {
		log.Panic().Msg(err.Error())
	}
	log.Info().Msg("Successfully connected to MongoDB")

	collection := client.Database("recommendation-db").Collection("recommendation")
	
	// Check if data already exists - skip generation and insertion if so
	existingCount, err := collection.CountDocuments(context.TODO(), map[string]interface{}{})
	if err != nil {
		log.Error().Msgf("Failed to count documents: %v", err)
		existingCount = 0
	}
	
	// Allow configurable hotel count for cache contention experiments
	hotelCount := defaultHotelCount
	if countStr := os.Getenv("HOTEL_COUNT"); countStr != "" {
		if count, err := strconv.Atoi(countStr); err == nil && count > 0 {
			hotelCount = count
		}
	}
	
	if existingCount > 0 {
		log.Info().Msgf("Database already has %d hotels, skipping data insertion (target: %d)", existingCount, hotelCount)
	} else {
		// Only generate data if we need to insert
		// Estimate: ~512 bytes per hotel (64 struct + 448 padding)
		workingSetMB := float64(hotelCount) * 512 / 1024 / 1024
		log.Info().Msgf("Database empty, generating %d hotels (estimated working set: ~%.1f MB)...", 
			hotelCount, workingSetMB)

		// Pre-allocate slice for efficiency
		newHotels := make([]interface{}, 0, hotelCount)
		
		// Keep original 6 hotels for compatibility
		newHotels = append(newHotels,
			Hotel{HId: "1", HLat: 37.7867, HLon: -122.4112, HRate: 109.00, HPrice: 150.00},
			Hotel{HId: "2", HLat: 37.7854, HLon: -122.4005, HRate: 139.00, HPrice: 120.00},
			Hotel{HId: "3", HLat: 37.7834, HLon: -122.4071, HRate: 109.00, HPrice: 190.00},
			Hotel{HId: "4", HLat: 37.7936, HLon: -122.3930, HRate: 129.00, HPrice: 160.00},
			Hotel{HId: "5", HLat: 37.7831, HLon: -122.4181, HRate: 119.00, HPrice: 140.00},
			Hotel{HId: "6", HLat: 37.7863, HLon: -122.4015, HRate: 149.00, HPrice: 200.00},
		)

		for i := 7; i <= hotelCount; i++ {
			rate := 135.00
			rateInc := 179.00
			hotelID := strconv.Itoa(i)
			// Spread hotels across a larger geographic area
			lat := 37.7835 + float64(i%1000)/500.0*3
			lon := -122.41 + float64(i%1000)/500.0*4

			if i%3 == 0 {
				switch i % 5 {
				case 1:
					rate = 120.00
					rateInc = 140.00
				case 2:
					rate = 124.00
					rateInc = 144.00
				case 3:
					rate = 132.00
					rateInc = 158.00
				case 4:
					rate = 232.00
					rateInc = 258.00
				default:
					rate = 109.00
					rateInc = 123.17
				}
			}

			newHotels = append(
				newHotels,
				Hotel{HId: hotelID, HLat: lat, HLon: lon, HRate: rate, HPrice: rateInc},
			)
		}

		// Insert in batches to avoid MongoDB bulk insert limits
		log.Info().Msgf("Inserting %d hotels into MongoDB...", len(newHotels))
		batchSize := 10000
		for i := 0; i < len(newHotels); i += batchSize {
			end := i + batchSize
			if end > len(newHotels) {
				end = len(newHotels)
			}
			batch := newHotels[i:end]
			_, err = collection.InsertMany(context.TODO(), batch)
			if err != nil {
				log.Fatal().Msgf("Failed to insert batch %d-%d: %v", i, end, err)
			}
			log.Info().Msgf("Inserted hotels %d-%d", i+1, end)
		}
		log.Info().Msgf("Successfully inserted %d hotels into recommendation DB", len(newHotels))
	}

	return client, func() {
		if err := client.Disconnect(context.TODO()); err != nil {
			log.Fatal().Msg(err.Error())
		}
	}
}
