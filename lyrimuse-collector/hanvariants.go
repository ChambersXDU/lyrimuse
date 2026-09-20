package main

import (
	"embed"
	"strings"
)

//go:embed dictionary/HanVariants.txt
var hanVariantsFS embed.FS

var hanVariantMap = loadHanVariants()

func loadHanVariants() map[rune]rune {
	out := map[rune]rune{}
	data, err := hanVariantsFS.ReadFile("dictionary/HanVariants.txt")
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		cols := strings.Split(line, "\t")
		if len(cols) < 2 {
			continue
		}
		src, dst := []rune(cols[0]), []rune(cols[1])
		if len(src) != 1 || len(dst) != 1 {
			continue
		}
		out[src[0]] = dst[0]
	}
	return out
}
