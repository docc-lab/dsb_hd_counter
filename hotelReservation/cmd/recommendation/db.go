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
// 5000 hotels ≈ 250-500 KB working set (larger than L2, fits in L3)
// Balance between cache contention sensitivity and request latency
const defaultHotelCount = 5000

type Hotel struct {
	HId    string  `bson:"hotelId"`
	HLat   float64 `bson:"lat"`
	HLon   float64 `bson:"lon"`
	HRate  float64 `bson:"rate"`
	HPrice float64 `bson:"price"`
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
		log.Info().Msgf("Database empty, generating %d hotels (working set: ~%.1f MB)...", 
			hotelCount, float64(hotelCount)*100/1024/1024)

		// Pre-allocate slice for efficiency
		newHotels := make([]interface{}, 0, hotelCount)
		
		// Keep original 6 hotels for compatibility
		newHotels = append(newHotels,
			Hotel{"1", 37.7867, -122.4112, 109.00, 150.00},
			Hotel{"2", 37.7854, -122.4005, 139.00, 120.00},
			Hotel{"3", 37.7834, -122.4071, 109.00, 190.00},
			Hotel{"4", 37.7936, -122.3930, 129.00, 160.00},
			Hotel{"5", 37.7831, -122.4181, 119.00, 140.00},
			Hotel{"6", 37.7863, -122.4015, 149.00, 200.00},
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
				Hotel{hotelID, lat, lon, rate, rateInc},
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
