package main

import "log"

func migrateBorrowedCoverAlbums() {
	enrichMu.Lock()
	cleared := 0
	for k, e := range enrichCache {

		if e.CoverSource != "qq" || e.CoverAlbum == "" {
			continue
		}
		e.CoverAlbum = ""
		enrichCache[k] = e
		cleared++
	}
	total := len(enrichCache)
	enrichMu.Unlock()
	if cleared > 0 {
		log.Printf("cover stamp migration: cleared borrowed cover_album on %d/%d qq-sourced entries", cleared, total)
		saveEnrichCache()
	}
}
