package main

import (
	"strings"
	"unicode"
)

var diacriticFolds = map[rune]string{
	'á': "a", 'à': "a", 'â': "a", 'ä': "a", 'ã': "a", 'å': "a", 'ā': "a", 'ă': "a", 'ą': "a",
	'é': "e", 'è': "e", 'ê': "e", 'ë': "e", 'ē': "e", 'ĕ': "e", 'ė': "e", 'ę': "e", 'ě': "e",
	'í': "i", 'ì': "i", 'î': "i", 'ï': "i", 'ī': "i", 'į': "i", 'ı': "i",
	'ó': "o", 'ò': "o", 'ô': "o", 'ö': "o", 'õ': "o", 'ō': "o", 'ő': "o",
	'ú': "u", 'ù': "u", 'û': "u", 'ü': "u", 'ū': "u", 'ů': "u", 'ű': "u", 'ų': "u",
	'ý': "y", 'ÿ': "y",
	'ñ': "n", 'ń': "n", 'ň': "n", 'ņ': "n",
	'ç': "c", 'ć': "c", 'č': "c", 'ĉ': "c",
	'š': "s", 'ś': "s", 'ş': "s", 'ș': "s",
	'ž': "z", 'ź': "z", 'ż': "z",
	'ł': "l", 'ľ': "l", 'ĺ': "l",
	'ř': "r", 'ŕ': "r",
	'ť': "t", 'ţ': "t", 'ț': "t",
	'ď': "d", 'đ': "d",
	'ğ': "g", 'ģ': "g",
	'ķ': "k", 'ĥ': "h", 'ĵ': "j", 'ŵ': "w",

	'ø': "o", 'œ': "oe", 'æ': "ae", 'ß': "ss", 'þ': "th", 'ð': "d",
}

var diacriticFoldsUpper = func() map[rune]string {
	m := make(map[rune]string, len(diacriticFolds))
	for r, folded := range diacriticFolds {
		upper := unicode.ToUpper(r)
		if upper == r {
			continue
		}

		m[upper] = strings.ToUpper(folded)
	}
	return m
}()

func foldRune(r rune) (string, bool) {
	if folded, ok := diacriticFolds[r]; ok {
		return folded, true
	}
	folded, ok := diacriticFoldsUpper[r]
	return folded, ok
}

func foldDiacritics(s string) string {

	hasAny := false
	for _, r := range s {
		if _, ok := foldRune(r); ok {
			hasAny = true
			break
		}
	}
	if !hasAny {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if folded, ok := foldRune(r); ok {
			b.WriteString(folded)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}
