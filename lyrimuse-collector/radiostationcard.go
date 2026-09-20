package main

import "strings"

func radioStationCard(radio bool, artist, title string) bool {
	return radio && strings.TrimSpace(artist) == "" && strings.TrimSpace(title) != ""
}
