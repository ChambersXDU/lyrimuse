package main

import "testing"

func TestArtistMatchesNameContainingSeparator(t *testing.T) {
	const long = "K/DA/Madison Beer/(G)I-DLE/Jaira Burns"
	const comma = "K/DA,Madison Beer,(G)I-DLE,Jaira Burns"
	const amp = "K/DA & Madison Beer & (G)I-DLE & Jaira Burns"

	cases := []struct {
		a, b string
		want bool
		why  string
	}{

		{"K/DA", long, true, "K/DA 是 long 开头一个 / 界定的片段"},
		{long, "K/DA", true, "反向也要成立(参数顺序无关)"},
		{"K/DA", comma, true, "逗号写法同样要认"},
		{"K/DA", amp, true, "& 写法同样要认"},

		{"Madison Beer", long, true, "整段相等"},
		{"(G)I-DLE", long, true, "整段相等(带括号)"},
		{"K/DA", "K/DA", true, "完全相同"},
		{"Prince", "Prince & The Revolution", true, "整段相等"},
		{"The Revolution", "Prince & The Revolution", true, "整段相等(多词)"},
		{"陶喆", "陶喆、卢广仲", true, "顿号分隔"},

		{"周杰伦", "周杰倫", true, "繁简同一个人,整串直接相等分支"},
		{"周杰倫", "周杰伦 & 王力宏", true, "繁简同一个人,段匹配分支"},

		{"丁世光", "丁世光(Dean Ting)", true, "去括号别名兜底,真实bug案例"},
		{"丁世光(Dean Ting)", "丁世光", true, "反向也要成立"},

		{"周杰伦(某某)", "周杰伦、", false, "括号别名 + 仿冒尾巴叠加,仿冒防线仍要挡住"},

		{"an", "anna", false, "子串但不是分隔符界定的片段"},
		{"da", "dave/eve", false, "首段的前缀不算(段是 dave)"},
		{"beer", long, false, "段中间的一个词不算(段是 madison beer)"},
		{"The", "Prince & The Revolution", false, "段里的一个词不算,空白不是边界"},
		{"Madison", long, false, "同上,别把半个名字放过去"},

		{"周杰伦", "周杰伦、", false, "仿冒特征:尾随分隔符,不能判成同一个人"},

		{"周杰倫", "周杰伦-", false, "仿冒特征换成繁体也一样挡住,toSimplified 不剥离标点"},

		{"K/DA", "IU/Suga", false, "毫无关系"},
		{"", long, false, "空串"},
		{"K/DA", "", false, "空串(反向)"},
	}

	for _, c := range cases {
		if got := artistMatches(c.a, c.b); got != c.want {
			t.Errorf("artistMatches(%q, %q) = %v, want %v —— %s", c.a, c.b, got, c.want, c.why)
		}
	}
}

func TestArtistCreditRunMatches(t *testing.T) {
	cases := []struct {
		hay, needle string
		want        bool
	}{
		{"k/da/madison beer", "k/da", true},
		{"madison beer/k/da", "k/da", true},
		{"a/k/da/b", "k/da", true},
		{"k/da & madison beer", "k/da", true},
		{"prince & the revolution", "the", false},
		{"anna", "an", false},
		{"dave/eve", "da", false},
		{"k/da", "k/da", true},
		{"k/da", "k/da/x", false},
		{"", "k", false},
		{"k", "", false},
	}
	for _, c := range cases {
		if got := artistCreditRunMatches(c.hay, c.needle); got != c.want {
			t.Errorf("artistCreditRunMatches(%q, %q) = %v, want %v", c.hay, c.needle, got, c.want)
		}
	}
}
