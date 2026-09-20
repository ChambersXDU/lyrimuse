package main

import "testing"

func TestFirstCreditedArtistSlashInName(t *testing.T) {
	cases := []struct{ in, want, why string }{

		{"K/DA/Madison Beer/i-dle/Jaira Burns", "K/DA",
			"头部 K 判不准 → 再吃一段得到 K/DA;这确实是个合唱串,第一位就是 K/DA"},
		{"K/DA / Madison Beer / i-dle / Jaira Burns", "K/DA",
			"带空格的斜杠写法同理(Apple Music 两种都报过)"},
		{"AC/DC", "AC/DC", "吃到整串仍判不准 = 整串本来就是一个名字,不切"},
		{"AC/DC/Guns N' Roses", "AC/DC", "AC ✗ → AC/DC ✓,别劈成 AC"},
		{"K/DA", "K/DA", "单独出现时不切"},

		{"K/DA, Madison Beer & i-dle", "K/DA", "逗号先命中,切出完整的 K/DA"},
		{"K/DA & Madison Beer", "K/DA", "& 先命中"},

		{"陶喆/卢广仲", "陶喆", "含汉字两个字就是完整名字"},
		{"英雄联盟/Sara Skinner", "英雄联盟", "汉字头部"},
		{"VALORANT/Grabbitz", "VALORANT", "拉丁头部 ≥3"},
		{"Imagine Dragons/JID/英雄联盟/双城之战", "Imagine Dragons", "拉丁多词头部"},
		{"Sebastien Najand/英雄联盟", "Sebastien Najand", "拉丁多词头部"},

		{"Prince & The Revolution", "Prince", "& 分隔"},
		{"陶喆、卢广仲", "陶喆", "顿号分隔"},
		{"周杰伦 & 派伟俊", "周杰伦", "全角空格 + &"},
		{"周杰伦", "周杰伦", "单人原样"},
		{"周杰伦、", "周杰伦、", "只切出一段 = 不是合唱,原样返回"},
		{"", "", "空串"},

		{"M/A/R/R/S", "M/A", "已知退化:全单字母段,吃两段后长度达标"},

		{"Khalil Fong和Fiona Sit", "Khalil Fong", "中文'和'连接两个拉丁艺名,应能拆开"},
		{"A和B和C", "A", "连续多个'和'——逐 rune 判断,不会漏掉后半段"},

		{"李和平", "李和平", "纯中文人名本身含'和',两侧中文段各只有1字,不该被切开"},
		{"和平", "和平", "'和'在开头,左侧没有字符,不该被当分隔符"},

		{"陶喆和盧廣仲", "陶喆", "两侧都是≥2字的中文段,应能拆开"},
	}
	for _, c := range cases {
		if got := firstCreditedArtist(c.in); got != c.want {
			t.Errorf("firstCreditedArtist(%q) = %q, want %q (%s)", c.in, got, c.want, c.why)
		}
	}
}

func TestSlashHeadPlausible(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"K", false}, {"AC", false}, {"AJR", true}, {"VALORANT", true},
		{"陶喆", true}, {"周", false}, {"英雄联盟", true}, {"", false},
	}
	for _, c := range cases {
		if got := slashHeadPlausible(c.in); got != c.want {
			t.Errorf("slashHeadPlausible(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}
