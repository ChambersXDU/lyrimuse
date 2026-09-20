package main

const radioDurationHintCap = 512

var radioDurationHints = map[string]float64{}

func noteRadioDuration(artist, title, album string, secs float64) {
	if secs <= 0 {
		return
	}
	key := enrichKey(artist, title, album)
	if key == "" {
		return
	}
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if len(radioDurationHints) >= radioDurationHintCap {
		radioDurationHints = map[string]float64{}
	}
	radioDurationHints[key] = secs
}

func applyRadioDurationHintLocked(key string, e *enrichEntry) bool {
	secs := radioDurationHints[key]
	if secs <= 0 {
		return false
	}
	if diff := e.DurationSecs - secs; diff > -0.5 && diff < 0.5 {
		return false
	}
	e.DurationSecs = secs
	return true
}
