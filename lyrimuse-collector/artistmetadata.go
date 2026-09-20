package main

import (
	"context"
	"encoding/json"
	"net/http"
	neturl "net/url"
	"strings"
	"time"
)

func artistMergeNameKey(name string) string {
	first := firstCreditedArtist(name)
	if alias := resolveGenericArtistCanonicalName(context.Background(), first); alias != "" {
		first = alias
	}
	return strings.ToLower(toSimplified(first))
}

func artistMergeDisplayName(name string) string {
	if alias := resolveGenericArtistCanonicalName(context.Background(), name); alias != "" {
		return alias
	}
	return name
}

func resolveArtistAvatar(ctx context.Context, name string) (string, bool) {
	qqPic, qqDef := qqSingerAvatar(ctx, name)
	if qqPic != "" {
		return qqPic, true
	}
	dzPic, dzDef := deezerArtistAvatar(ctx, name)
	if dzPic != "" {
		return dzPic, true
	}

	return "", qqDef && dzDef
}

func deezerArtistAvatar(ctx context.Context, name string) (string, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	u := "https://api.deezer.com/search/artist?limit=1&q=" + neturl.QueryEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", false
	}
	resp, err := doHTTPTracked(http.DefaultClient, req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	var out struct {
		Data []struct {
			PictureMedium string `json:"picture_medium"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", false
	}
	if len(out.Data) == 0 {
		return "", true
	}
	return out.Data[0].PictureMedium, true
}
