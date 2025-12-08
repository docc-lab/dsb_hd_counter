package main

import (
	"context"
	"fmt"
	"strconv"

	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type point struct {
	Pid  string  `bson:"hotelId"`
	Plat float64 `bson:"lat"`
	Plon float64 `bson:"lon"`
}

func initializeDatabase(url string) (*mongo.Client, func()) {
	log.Info().Msg("Generating test data...")

	newPoints := []interface{}{
		point{"1", 37.7867, -122.4112},
		point{"2", 37.7854, -122.4005},
		point{"3", 37.7854, -122.4071},
		point{"4", 37.7936, -122.3930},
		point{"5", 37.7831, -122.4181},
		point{"6", 37.7863, -122.4015},
	}

	// Match profile service hotel count for consistency
	const hotelCount = 20000
	
	for i := 7; i <= hotelCount; i++ {
		hotelID := strconv.Itoa(i)
		// Spread hotels across geographic area (match profile logic)
		lat := 37.7835 + float64(i%1000)/500.0*3
		lon := -122.41 + float64(i%1000)/500.0*4

		newPoints = append(newPoints, point{hotelID, lat, lon})
	}
	log.Info().Msgf("Generated %d geo points", len(newPoints))

	uri := fmt.Sprintf("mongodb://%s", url)
	log.Info().Msgf("Attempting connection to %v", uri)

	opts := options.Client().ApplyURI(uri)
	client, err := mongo.Connect(context.TODO(), opts)
	if err != nil {
		log.Panic().Msg(err.Error())
	}
	log.Info().Msg("Successfully connected to MongoDB")

	collection := client.Database("geo-db").Collection("geo")
	
	// Insert in batches to avoid MongoDB bulk insert limits
	log.Info().Msgf("Inserting %d geo points into MongoDB...", len(newPoints))
	batchSize := 10000
	for i := 0; i < len(newPoints); i += batchSize {
		end := i + batchSize
		if end > len(newPoints) {
			end = len(newPoints)
		}
		batch := newPoints[i:end]
		_, err = collection.InsertMany(context.TODO(), batch)
		if err != nil {
			log.Fatal().Msgf("Failed to insert batch %d-%d: %v", i, end, err)
		}
		log.Info().Msgf("Inserted geo points %d-%d", i+1, end)
	}
	log.Info().Msgf("Successfully inserted %d geo points into geo DB", len(newPoints))

	return client, func() {
		if err := client.Disconnect(context.TODO()); err != nil {
			log.Fatal().Msg(err.Error())
		}
	}
}
