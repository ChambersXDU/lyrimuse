package main

import (
	"image"
	"image/color"
	"testing"
)

func synthCover(edge int, seed int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, edge, edge))
	for y := 0; y < edge; y++ {
		for x := 0; x < edge; x++ {

			fx := float64(x) / float64(edge)
			fy := float64(y) / float64(edge)
			v := 40 + 180*fx*fy

			if int(fx*4)+int(fy*4)+seed%3 == seed%5 {
				v = 250 - v
			}
			if seed%2 == 1 && fx > 0.6 && fy < 0.4 {
				v = 255 - v
			}
			c := uint8(v)
			img.Set(x, y, color.RGBA{R: c, G: c / 2, B: 255 - c, A: 255})
		}
	}
	return img
}

func solidCover(edge int, v uint8) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, edge, edge))
	for y := 0; y < edge; y++ {
		for x := 0; x < edge; x++ {
			img.Set(x, y, color.RGBA{R: v, G: v, B: v, A: 255})
		}
	}
	return img
}

func TestCoverFingerprintStableAcrossScale(t *testing.T) {
	base := coverFingerprint(synthCover(64, 1))
	for _, edge := range []int{80, 120, 300, 800, 1400} {
		got := coverFingerprint(synthCover(edge, 1))
		if d := coverFingerprintDistance(base, got); d > coverFingerprintMaxDistance {
			t.Errorf("同一张图 %dpx 版的指纹距离 64px 版 = %d,超过阈值 %d", edge, d, coverFingerprintMaxDistance)
		}
	}

	other := coverFingerprint(synthCover(800, 4))
	if d := coverFingerprintDistance(base, other); d <= coverFingerprintMaxDistance {
		t.Errorf("两张不同的图距离只有 %d,阈值 %d 分不开", d, coverFingerprintMaxDistance)
	}
}

func TestCoverImagesLikelySame(t *testing.T) {
	if !coverImagesLikelySame(synthCover(120, 1), synthCover(800, 1)) {
		t.Error("同一张图的两个分辨率该判成同一张")
	}
	if coverImagesLikelySame(synthCover(120, 1), synthCover(800, 4)) {
		t.Error("两张不同的图不该判成同一张")
	}

	if coverImagesLikelySame(nil, synthCover(120, 1)) || coverImagesLikelySame(synthCover(120, 1), nil) {
		t.Error("nil 不该判成同一张")
	}
	if coverImagesLikelySame(solidCover(120, 128), solidCover(800, 200)) {
		t.Error("纯色图指纹退化成全 0,不该被当成同一张")
	}
}

func TestCoverURLIntendedEdge(t *testing.T) {
	cases := []struct {
		url  string
		want int
	}{

		{"https://p2.music.126.net/O0rm==/109951166232338422.jpg?param=800y800", 800},
		{"https://p1.music.126.net/abc==/123.jpg?param=64y64", 64},
		{"https://p1.music.126.net/abc==/123.jpg?param=300x300", 300},
		{"https://p1.music.126.net/abc==/123.jpg?param=800y800&foo=1", 800},

		{"https://is1-ssl.mzstatic.com/image/thumb/abc/600x600bb.jpg", 600},

		{"https://y.qq.com/music/photo_new/T002R800x800M000abc.jpg", 800},

		{"https://example.com/cover.jpg", 0},
		{"", 0},
		{"file:///Users/x/.config/lyrimuse/artwork/5b8fe093a7f81d31.jpg", 0},

		{"https://example.com/a/12x34/cover.jpg", 0},
	}
	for _, c := range cases {
		if got := coverURLIntendedEdge(c.url); got != c.want {
			t.Errorf("coverURLIntendedEdge(%q) = %d, want %d", c.url, got, c.want)
		}
	}
}

func TestDeviceCoverDecision(t *testing.T) {
	const neteaseBig = "https://p1.music.126.net/abc==/1.jpg?param=800y800"
	load := func(img image.Image) func(string) image.Image {
		return func(string) image.Image { return img }
	}
	neverLoad := func(string) image.Image {
		t.Error("这一档不该发起取图")
		return nil
	}

	if ov, why := deviceCoverDecision(synthCover(600, 1), neteaseBig, 800, neverLoad); !ov {
		t.Errorf("够清晰的设备封面该顶掉候选, why=%s", why)
	}

	if ov, _ := deviceCoverDecision(synthCover(deviceCoverTrustedMinEdge, 1), neteaseBig, 800, neverLoad); !ov {
		t.Error("边长正好等于门槛该算够清晰")
	}

	if ov, _ := deviceCoverDecision(synthCover(120, 1), "", 0, neverLoad); !ov {
		t.Error("没有候选时该用设备封面")
	}
	if ov, _ := deviceCoverDecision(synthCover(120, 1), "   ", 0, neverLoad); !ov {
		t.Error("候选是纯空白时该用设备封面")
	}

	if ov, why := deviceCoverDecision(synthCover(120, 1), "https://example.com/c.jpg", 0, neverLoad); !ov {
		t.Errorf("候选尺寸认不出时该保留设备封面, why=%s", why)
	}

	if ov, _ := deviceCoverDecision(synthCover(120, 1), neteaseBig, 120, neverLoad); !ov {
		t.Error("候选跟设备图一样大时该保留设备封面")
	}
	if ov, _ := deviceCoverDecision(synthCover(120, 1), neteaseBig, 64, neverLoad); !ov {
		t.Error("候选比设备图小时该保留设备封面")
	}

	ov, why := deviceCoverDecision(synthCover(120, 1), neteaseBig, 800, load(synthCover(800, 1)))
	if ov {
		t.Errorf("同一张图时该改用更清晰的候选, why=%s", why)
	}

	ov, why = deviceCoverDecision(synthCover(120, 1), neteaseBig, 800, load(synthCover(800, 4)))
	if !ov {
		t.Errorf("候选是另一张图时必须保留设备封面(否则 Immortal 那个 bug 复发), why=%s", why)
	}

	if ov, _ := deviceCoverDecision(synthCover(120, 1), neteaseBig, 800, load(nil)); !ov {
		t.Error("候选取不到时该保留设备封面")
	}

	if ov, _ := deviceCoverDecision(nil, neteaseBig, 800, neverLoad); ov {
		t.Error("设备图解不出来时不该顶掉候选")
	}
}

func TestMinEdge(t *testing.T) {
	if got := minEdge(image.NewRGBA(image.Rect(0, 0, 120, 300))); got != 120 {
		t.Errorf("minEdge 该取短边, got %d", got)
	}
	if got := minEdge(image.NewRGBA(image.Rect(0, 0, 300, 120))); got != 120 {
		t.Errorf("minEdge 该取短边(反向), got %d", got)
	}
	if got := minEdge(nil); got != 0 {
		t.Errorf("minEdge(nil) 该是 0, got %d", got)
	}
}
