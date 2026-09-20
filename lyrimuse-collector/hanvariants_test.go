package main

import "testing"

func TestHanVariantsFoldsSearchTerms(t *testing.T) {
	cases := []struct{ in, want string }{

		{"妳聽得到", "你听得到"},

		{"妳听得到", "你听得到"},
		{"祂的孩子", "他的孩子"},
		{"牠的名字", "它的名字"},
		{"細雨濛濛", "细雨蒙蒙"},

		{"你听得到", "你听得到"},
		{"周杰伦", "周杰伦"},

		{"Hello 妳好", "Hello 你好"},
	}
	for _, c := range cases {
		if got := toSimplified(c.in); got != c.want {
			t.Errorf("toSimplified(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestHanVariantsTableInvariants(t *testing.T) {
	if len(hanVariantMap) < 100 {
		t.Fatalf("异体字表只有 %d 条,像是 embed 没读到(产物在 dictionary/HanVariants.txt)", len(hanVariantMap))
	}
	for src, dst := range hanVariantMap {
		if src == dst {
			t.Errorf("%c → 自己,这条没有意义", src)
		}

		if next, ok := hanVariantMap[dst]; ok {
			t.Errorf("%c → %c → %c 成链了,逐字替换只跑一遍,结果会不确定", src, dst, next)
		}

		if again := toSimplified(string(dst)); again != string(dst) {
			t.Errorf("%c → %c,但 %c 自己还会被繁简转换改成 %s", src, dst, dst, again)
		}
	}
}

func TestHanVariantsIdempotent(t *testing.T) {
	for _, s := range []string{"妳聽得到", "祂與牠", "細雨濛濛", "痲痺"} {
		once := toSimplified(s)
		if twice := toSimplified(once); twice != once {
			t.Errorf("toSimplified 不幂等:%q → %q → %q", s, once, twice)
		}
	}
}
