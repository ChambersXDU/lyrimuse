package main

import "testing"

func TestDurationParam(t *testing.T) {
	cases := []struct {
		name string
		secs float64
		want string
	}{
		{"正常曲长取整数秒", 322.018, "322"},
		{"向下取整,不四舍五入(跟 backfill 的 int64() 转换逐字一致)", 208.9, "208"},
		{"拿不到曲长(0)不发这个键", 0, ""},
		{"负数不发(异常值,发出去等于断言了一个假事实)", -5, ""},
		{"刚好 1 秒仍然发", 1, "1"},
	}
	for _, c := range cases {
		p := map[string]string{}
		durationParam(p, "duration", c.secs)
		got, ok := p["duration"]
		if c.want == "" {
			if ok {
				t.Errorf("%s: 不该有 duration 键, got %q", c.name, got)
			}
			continue
		}
		if got != c.want {
			t.Errorf("%s: duration = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestDurationParamHonorsKeyName(t *testing.T) {
	p := map[string]string{}
	durationParam(p, "duration[3]", 180)
	if p["duration[3]"] != "180" {
		t.Fatalf("带下标的键名没生效: %+v", p)
	}
	if _, ok := p["duration"]; ok {
		t.Fatal("不该顺手写一个裸 duration 键")
	}
}
