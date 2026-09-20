package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type avatarCacheEntry struct {
	URL string `json:"url"`
	TS  int64  `json:"ts"`

	Transient bool `json:"transient,omitempty"`
}

const avatarCacheTTL = 14 * 24 * time.Hour
const avatarTransientTTL = 30 * time.Minute

func runArtistAvatarsCLI(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "artist-avatars: at least one artist name is required")
		os.Exit(2)
	}
	if configDir() == "" {
		log.Fatalf("artist-avatars: cannot resolve home directory (and LYRIMUSE_CONFIG_DIR is unset)")
	}
	cachePath := filepath.Join(configDir(), clientName+"-artist-avatar-cache.json")

	cache := map[string]avatarCacheEntry{}
	if data, err := os.ReadFile(cachePath); err == nil {

		_ = json.Unmarshal(data, &cache)
	}

	out := map[string]string{}
	dirty := false
	now := time.Now()

	var misses []string
	for _, name := range args {
		if name == "" {
			continue
		}
		if old, ok := cache[name]; ok {
			ttl := avatarCacheTTL
			if old.Transient {
				ttl = avatarTransientTTL
			}
			if now.Sub(time.Unix(old.TS, 0)) < ttl {
				out[name] = old.URL
				continue
			}
		}
		misses = append(misses, name)
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for _, name := range misses {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
			url, definitive := resolveArtistAvatar(ctx, name)
			cancel()
			mu.Lock()
			defer mu.Unlock()
			old, hasOld := cache[name]
			switch {
			case url != "" || definitive:

				out[name] = url
				cache[name] = avatarCacheEntry{URL: url, TS: now.Unix()}
				dirty = true
			case hasOld && old.URL != "":

				out[name] = old.URL
			default:

				out[name] = ""
				cache[name] = avatarCacheEntry{URL: "", TS: now.Unix(), Transient: true}
				dirty = true
			}
		}(name)
	}
	wg.Wait()

	if dirty {
		if data, err := json.MarshalIndent(cache, "", "  "); err == nil {

			tmp := cachePath + ".tmp"
			if err := os.WriteFile(tmp, data, 0o644); err != nil {
				log.Printf("artist-avatars: write cache failed: %v", err)
			} else if err := os.Rename(tmp, cachePath); err != nil {
				log.Printf("artist-avatars: rename cache failed: %v", err)
			}
		}
	}

	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		log.Fatalf("artist-avatars: encode: %v", err)
	}
}
