package main

import (
	"testing"
	"unicode"
)

func TestFoldDiacritics(t *testing.T) {
	cases := map[string]string{
		"Beyoncé":     "Beyonce",
		"Rosalía":     "Rosalia",
		"Sigur Rós":   "Sigur Ros",
		"Mötley Crüe": "Motley Crue",
		"Björk":       "Bjork",
		"Céline Dion": "Celine Dion",
		"Antônio":     "Antonio",
		"Håkan":       "Hakan",
		"Renée":       "Renee",

		"Straße": "Strasse",
		"Søren":  "Soren",

		"周杰伦":          "周杰伦",
		"宇多田ヒカル":       "宇多田ヒカル",
		"Taylor Swift": "Taylor Swift",
		"2Pac":         "2Pac",
		"AC/DC":        "AC/DC",
		"":             "",

		"Æther":     "AEther",
		"ÅKERFELDT": "AKERFELDT",
		"ÑOÑO":      "NONO",
		"Ø":         "O",
	}
	for in, want := range cases {
		if got := foldDiacritics(in); got != want {
			t.Errorf("foldDiacritics(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFoldTableCoversUppercase(t *testing.T) {
	for r := range diacriticFolds {
		upper := unicode.ToUpper(r)
		if upper == r {
			continue
		}
		if _, ok := foldRune(upper); !ok {
			t.Errorf("大写 %q (来自 %q) 没有被覆盖", string(upper), string(r))
		}
	}
}

func TestNormLooseFoldsDiacritics(t *testing.T) {
	pairs := [][2]string{
		{"Beyoncé", "Beyonce"},
		{"Sigur Rós", "sigur ros"},
		{"Mötley Crüe", "Motley Crue"},
		{"Rosalía - MALAMENTE", "Rosalia MALAMENTE"},
	}
	for _, p := range pairs {
		if normLoose(p[0]) != normLoose(p[1]) {
			t.Errorf("normLoose(%q)=%q != normLoose(%q)=%q",
				p[0], normLoose(p[0]), p[1], normLoose(p[1]))
		}
	}

	if normLoose("Sade") == normLoose("Suede") {
		t.Error("折叠过度：Sade 和 Suede 不该相等")
	}

	if normLoose("周杰倫") != normLoose("周杰伦") {
		t.Error("繁简归一被破坏了")
	}
}
