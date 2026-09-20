package main

import "testing"

func TestQQAlbumTiedSongsAreSameTrack(t *testing.T) {
	cases := []struct {
		name string
		tied []qqAlbumSong
		want bool
	}{
		{

			"同一张专辑上架两遍,同名同歌手同时长",
			[]qqAlbumSong{
				{mid: "002ZZkxD2Niba1", name: "寻找一片青草地", singer: "裘德", interval: 221},
				{mid: "0023jZIS4Ml5xu", name: "寻找一片青草地", singer: "裘德", interval: 221},
			},
			true,
		},
		{

			"时长差 7 秒仍算同一首",
			[]qqAlbumSong{
				{mid: "a", name: "银色荒原", singer: "裘德", interval: 240},
				{mid: "b", name: "银色荒原", singer: "裘德", interval: 247},
			},
			true,
		},
		{

			"时长差 40 秒 → 真·不同版本,放弃",
			[]qqAlbumSong{
				{mid: "a", name: "龙拳", singer: "周杰伦", interval: 200},
				{mid: "b", name: "龙拳", singer: "周杰伦", interval: 240},
			},
			false,
		},
		{

			"同名但歌手不同 → 放弃",
			[]qqAlbumSong{
				{mid: "a", name: "小情歌", singer: "苏打绿", interval: 250},
				{mid: "b", name: "小情歌", singer: "某翻唱", interval: 250},
			},
			false,
		},
		{

			"归一化后不同名 → 放弃",
			[]qqAlbumSong{
				{mid: "a", name: "寻找一片青草地", singer: "裘德", interval: 221},
				{mid: "b", name: "寻找一片青草地 (伴奏)", singer: "裘德", interval: 221},
			},
			false,
		},
		{

			"缺时长 → 核不了,放弃",
			[]qqAlbumSong{
				{mid: "a", name: "某曲", singer: "某人", interval: 0},
				{mid: "b", name: "某曲", singer: "某人", interval: 0},
			},
			false,
		},
		{

			"只有第一条缺时长 → 同样核不了,放弃",
			[]qqAlbumSong{
				{mid: "a", name: "某曲", singer: "某人", interval: 0},
				{mid: "b", name: "某曲", singer: "某人", interval: 8},
			},
			false,
		},
		{
			"只有一条时也应成立(调用方对单条不走这个判据,但函数本身要自洽)",
			[]qqAlbumSong{{mid: "a", name: "某曲", singer: "某人", interval: 200}},
			true,
		},
		{"空切片", nil, false},
	}
	for _, c := range cases {
		if got := qqAlbumTiedSongsAreSameTrack(c.tied); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestPickQQAlbumTrackHandlesDoubleListedAlbum(t *testing.T) {

	album := []qqAlbumSong{
		{mid: "003C6uoW3TRsod", name: "银色荒原", singer: "裘德", interval: 240},
		{mid: "0018yJhH3fxaJm", name: "火山灰", singer: "裘德", interval: 277},
		{mid: "000S5SKd2IYzXh", name: "春天的临终", singer: "裘德", interval: 282},
		{mid: "002XiEr80jaw70", name: "飞鸟在风暴中", singer: "裘德", interval: 327},
		{mid: "000KM2qt3lx50r", name: "奇卡奇卡", singer: "裘德", interval: 177},
		{mid: "0020GiE02VMADK", name: "变色龙", singer: "裘德/吴青峰", interval: 209},
		{mid: "001yUXxe2AfN2R", name: "没有羊的牧羊人", singer: "裘德", interval: 279},
		{mid: "000rNaTW106smh", name: "请求迷失在七月森林", singer: "裘德/孙盛希", interval: 292},
		{mid: "002ggjaX0xnbqi", name: "我们不要躲雨了", singer: "裘德", interval: 260},
		{mid: "002ZZkxD2Niba1", name: "寻找一片青草地", singer: "裘德", interval: 221},
		{mid: "002Kwihi0MJICc", name: "银色荒原", singer: "裘德", interval: 247},
		{mid: "0018cZzB0KEuTx", name: "火山灰", singer: "裘德", interval: 277},
		{mid: "002zM0Qx0z0H6h", name: "春天的临终", singer: "裘德", interval: 282},
		{mid: "004aw8Yz0CeoZb", name: "飞鸟在风暴中", singer: "裘德", interval: 328},
		{mid: "003sS2By1P8RgX", name: "奇卡奇卡", singer: "裘德", interval: 177},
		{mid: "002CHe7F1awrUu", name: "变色龙", singer: "裘德/吴青峰", interval: 211},
		{mid: "0016R7Zr4RrhTp", name: "没有羊的牧羊人", singer: "裘德", interval: 279},
		{mid: "001iIR2f4f6MjR", name: "请求迷失在七月森林", singer: "裘德", interval: 292},
		{mid: "002N66hL2lpaQs", name: "我们不要躲雨了", singer: "裘德", interval: 262},
		{mid: "0023jZIS4Ml5xu", name: "寻找一片青草地", singer: "裘德", interval: 221},
	}

	for _, title := range []string{"寻找一片青草地", "火山灰", "变色龙", "银色荒原"} {
		got, ok := pickQQAlbumTrack(album, "裘德", title)
		if !ok {
			t.Errorf("%q: 整张专辑上架两遍不该让它挑不出来", title)
			continue
		}
		if got.name != title {
			t.Errorf("%q: 挑中的是 %q", title, got.name)
		}
	}

	twoLive := []qqAlbumSong{
		{mid: "a", name: "龙拳", singer: "周杰伦", interval: 200},
		{mid: "b", name: "龙拳", singer: "周杰伦", interval: 260},
	}
	if _, ok := pickQQAlbumTrack(twoLive, "周杰伦", "龙拳"); ok {
		t.Error("同名但时长差 60 秒(两场不同现场)不该被认成同一首")
	}

	tiered := []qqAlbumSong{
		{mid: "strip", name: "某曲 (Live)", singer: "某人", interval: 200},
		{mid: "exact", name: "某曲", singer: "某人", interval: 200},
	}
	got, ok := pickQQAlbumTrack(tiered, "某人", "某曲")
	if !ok || got.mid != "exact" {
		t.Errorf("精确同名档应优先,得到 ok=%v mid=%q", ok, got.mid)
	}
}
