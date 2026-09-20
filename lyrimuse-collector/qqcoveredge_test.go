package main

import "testing"

func TestQQCoverAtEdge(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		edge string
		want string
	}{
		{
			name: "专辑封面 300 提到 800",
			raw:  "https://y.qq.com/music/photo_new/T002R300x300M0000017AN4b0vdUG1.jpg",
			edge: "800",
			want: "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
		},
		{
			name: "专辑封面 500 提到 800",
			raw:  "https://y.qq.com/music/photo_new/T002R500x500M0000017AN4b0vdUG1.jpg",
			edge: "800",
			want: "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
		},
		{
			name: "已经是 800 就原样",
			raw:  "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
			edge: "800",
			want: "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
		},
		{
			name: "歌手头像 T001 同一套规则(y.gtimg.cn)",
			raw:  "https://y.gtimg.cn/music/photo_new/T001R150x150M000004UdEhN3Hb7vN_3.jpg",
			edge: "300",
			want: "https://y.gtimg.cn/music/photo_new/T001R300x300M000004UdEhN3Hb7vN_3.jpg",
		},
		{
			name: "取色路径反向降档",
			raw:  "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
			edge: "300",
			want: "https://y.qq.com/music/photo_new/T002R300x300M0000017AN4b0vdUG1.jpg",
		},
		{
			name: "网易云封面不许动",
			raw:  "https://p1.music.126.net/abc==/109951171031632866.jpg?param=600y600",
			edge: "800",
			want: "https://p1.music.126.net/abc==/109951171031632866.jpg?param=600y600",
		},
		{
			name: "Apple 封面不许动",
			raw:  "https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/600x600bb.jpg",
			edge: "800",
			want: "https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/600x600bb.jpg",
		},
		{
			name: "QQ 域名但不是图床路径",
			raw:  "https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49",
			edge: "800",
			want: "https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49",
		},
		{
			name: "图床路径但没有尺寸段",
			raw:  "https://y.qq.com/music/photo_new/mystery.jpg",
			edge: "800",
			want: "https://y.qq.com/music/photo_new/mystery.jpg",
		},
		{
			name: "空串",
			raw:  "",
			edge: "800",
			want: "",
		},
		{
			name: "空 edge 不动(防止拼出 TxRxM 这种废 URL)",
			raw:  "https://y.qq.com/music/photo_new/T002R300x300M0000017AN4b0vdUG1.jpg",
			edge: "",
			want: "https://y.qq.com/music/photo_new/T002R300x300M0000017AN4b0vdUG1.jpg",
		},
	}
	for _, c := range cases {
		if got := qqCoverAtEdge(c.raw, c.edge); got != c.want {
			t.Errorf("%s: qqCoverAtEdge(%q, %q) = %q, want %q", c.name, c.raw, c.edge, got, c.want)
		}
	}
}

func TestQQAlbumCoverURL(t *testing.T) {
	got := qqAlbumCoverURL("0017AN4b0vdUG1")
	want := "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg"
	if got != want {
		t.Errorf("qqAlbumCoverURL = %q, want %q", got, want)
	}
	if got := qqAlbumCoverURL(""); got != "" {
		t.Errorf("空 mid 应该给空串,得到 %q", got)
	}
}
