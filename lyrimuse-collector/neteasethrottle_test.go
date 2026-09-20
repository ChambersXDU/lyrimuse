package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestNeteaseThrottle(t *testing.T) {
	savedCall := neteaseLastCall
	savedCooldown := neteaseCooldownUntil
	t.Cleanup(func() {
		neteaseLastCall = savedCall
		neteaseCooldownUntil = savedCooldown
	})
	resetCooldowns := func() { neteaseCooldownUntil = map[string]time.Time{} }

	t.Run("很久没调用过时不等待", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		start := time.Now()
		if err := neteaseThrottle(context.Background(), "https://music.163.com/api/search/get/web"); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
			t.Errorf("不该等待,实际等了 %v", elapsed)
		}
	})

	t.Run("紧接着再调用一次要等满最小间隔", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now()
		start := time.Now()
		if err := neteaseThrottle(context.Background(), "https://music.163.com/api/search/get/web"); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		elapsed := time.Since(start)
		if elapsed < neteaseMinIntervalBetweenCalls-10*time.Millisecond {
			t.Errorf("等待时间 %v 短于最小间隔 %v", elapsed, neteaseMinIntervalBetweenCalls)
		}
	})

	t.Run("等待中途取消:提前返回错误,不占用这次调用名额", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
		defer cancel()
		beforeCall := neteaseLastCall
		start := time.Now()
		err := neteaseThrottle(ctx, "https://music.163.com/api/search/get/web")
		if err == nil {
			t.Fatal("ctx 超时应该返回错误,got nil")
		}
		if elapsed := time.Since(start); elapsed > neteaseMinIntervalBetweenCalls {
			t.Errorf("应该在 ctx 超时(10ms)时就提前返回,实际等了 %v", elapsed)
		}
		if neteaseLastCall != beforeCall {
			t.Error("取消等待不该更新 neteaseLastCall,不然会占用一次不存在的调用名额")
		}
	})

	t.Run("退避期内的端点桶立刻拒绝,不睡", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		const blocked = "https://music.163.com/api/search/get/web?type=1&s=a"
		neteaseReportBlocked(blocked, time.Second)

		start := time.Now()
		err := neteaseThrottle(context.Background(), blocked)
		if !errors.Is(err, errNeteaseBucketCooling) {
			t.Fatalf("neteaseThrottle() = %v, want errNeteaseBucketCooling", err)
		}
		if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
			t.Errorf("退避期内应当立刻返回,实际等了 %v", elapsed)
		}
	})

	t.Run("退避期过了就正常放行", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		const blocked = "https://music.163.com/api/search/get/web?type=1&s=a"
		neteaseReportBlocked(blocked, 20*time.Millisecond)
		time.Sleep(40 * time.Millisecond)

		if err := neteaseThrottle(context.Background(), blocked); err != nil {
			t.Fatalf("退避期已过,应当放行,got %v", err)
		}
	})

	t.Run("不同路径不共享退避:换成另一个端点的备用桶立刻放行", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		const primary = "https://music.163.com/api/search/get/web?type=1&s=a"
		const fallback = "https://music.163.com/api/search/get?type=1&s=a"
		neteaseReportBlocked(primary, time.Second)

		start := time.Now()
		if err := neteaseThrottle(context.Background(), fallback); err != nil {
			t.Fatalf("neteaseThrottle() = %v, want nil", err)
		}
		if elapsed := time.Since(start); elapsed > 50*time.Millisecond {
			t.Errorf("备用端点不该被主端点的退避连带卡住,实际等了 %v", elapsed)
		}
	})

	t.Run("同一路径不同 query 共享同一个桶", func(t *testing.T) {
		resetCooldowns()
		neteaseLastCall = time.Now().Add(-time.Hour)
		neteaseReportBlocked("https://music.163.com/api/search/get/web?type=1&s=a", time.Second)

		err := neteaseThrottle(context.Background(), "https://music.163.com/api/search/get/web?type=10&s=b")
		if !errors.Is(err, errNeteaseBucketCooling) {
			t.Fatalf("同路径不同 query 应该共享退避,got %v", err)
		}
	})

	t.Run("退避只会延长不会缩短", func(t *testing.T) {
		resetCooldowns()
		const u = "https://music.163.com/api/search/get/web"
		neteaseReportBlocked(u, 200*time.Millisecond)
		neteaseReportBlocked(u, 20*time.Millisecond)
		until := neteaseCooldownUntil[neteaseEndpointBucket(u)]
		if time.Until(until) < 150*time.Millisecond {
			t.Errorf("更短的退避不该覆盖已有的更长退避,剩余 %v", time.Until(until))
		}
	})
}

func TestNeteaseEndpointBucket(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		same bool
	}{
		{"同路径不同query同桶", "https://music.163.com/api/search/get/web?type=1", "https://music.163.com/api/search/get/web?type=10", true},
		{"不同路径不同桶", "https://music.163.com/api/search/get/web", "https://music.163.com/api/search/get", false},
		{"不同端点族不同桶", "https://music.163.com/api/song/lyric?id=1", "https://music.163.com/api/song/lyric/v1?id=1", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := neteaseEndpointBucket(c.a) == neteaseEndpointBucket(c.b)
			if got != c.same {
				t.Errorf("neteaseEndpointBucket(%q)==neteaseEndpointBucket(%q) = %v, want %v", c.a, c.b, got, c.same)
			}
		})
	}
}

func TestNeteaseBlockBackoff(t *testing.T) {
	savedCooldown := neteaseCooldownUntil
	savedStreak := neteaseBlockStreak
	savedSuccess := neteaseAnySuccess
	t.Cleanup(func() {
		neteaseCooldownUntil = savedCooldown
		neteaseBlockStreak = savedStreak
		neteaseAnySuccess = savedSuccess
	})
	reset := func() {
		neteaseCooldownUntil = map[string]time.Time{}
		neteaseBlockStreak = map[string]int{}
		neteaseAnySuccess = false
	}

	t.Run("连撞几次就退避几档,到上限封顶", func(t *testing.T) {
		cases := []struct {
			streak int
			want   time.Duration
		}{
			{1, neteaseBlockCooldownBase},
			{2, 2 * neteaseBlockCooldownBase},
			{3, 4 * neteaseBlockCooldownBase},
			{4, neteaseBlockCooldownMax},
			{9, neteaseBlockCooldownMax},
		}
		for _, c := range cases {
			if got := neteaseCooldownForStreak(c.streak); got != c.want {
				t.Errorf("neteaseCooldownForStreak(%d) = %v, want %v", c.streak, got, c.want)
			}
		}
	})

	t.Run("streak 大到会移位溢出时仍然是正数且不超上限", func(t *testing.T) {
		for _, streak := range []int{32, 63, 64, 1 << 20} {
			got := neteaseCooldownForStreak(streak)
			if got <= 0 {
				t.Fatalf("neteaseCooldownForStreak(%d) = %v,负/零退避等于没有退避", streak, got)
			}
			if got != neteaseBlockCooldownMax {
				t.Errorf("neteaseCooldownForStreak(%d) = %v, want 封顶 %v", streak, got, neteaseBlockCooldownMax)
			}
		}

		if got := neteaseCooldownForStreak(0); got != neteaseBlockCooldownBase {
			t.Errorf("neteaseCooldownForStreak(0) = %v, want %v", got, neteaseBlockCooldownBase)
		}
	})

	t.Run("同一个桶连续被拒:退避一次比一次长,连撞计数递增", func(t *testing.T) {
		reset()
		const u = "https://music.163.com/api/search/get/web?type=1&s=a"
		d1, s1 := neteaseReportRejected(u)
		d2, s2 := neteaseReportRejected(u)
		if s1 != 1 || s2 != 2 {
			t.Fatalf("连撞计数 = %d,%d, want 1,2", s1, s2)
		}
		if !(d2 > d1) {
			t.Errorf("第二次退避 %v 不比第一次 %v 长", d2, d1)
		}
		if d1 != neteaseBlockCooldownBase {
			t.Errorf("首次退避 = %v, want %v", d1, neteaseBlockCooldownBase)
		}
	})

	t.Run("不同桶各自记连撞,不互相污染", func(t *testing.T) {
		reset()
		_, _ = neteaseReportRejected("https://music.163.com/api/search/get/web?type=1&s=a")
		_, _ = neteaseReportRejected("https://music.163.com/api/search/get/web?type=10&s=b")
		_, streak := neteaseReportRejected("https://music.163.com/api/search/get?type=1&s=a")
		if streak != 1 {
			t.Errorf("另一个桶的首次拒绝 streak = %d, want 1", streak)
		}
	})

	t.Run("成功一次就清零:连撞计数复原、冷却标记清掉、下次被拒重新从 base 起算", func(t *testing.T) {
		reset()
		const u = "https://music.163.com/api/search/get/web?type=1&s=a"
		neteaseReportRejected(u)
		neteaseReportRejected(u)
		neteaseReportRejected(u)
		if err := neteaseThrottle(context.Background(), u); !errors.Is(err, errNeteaseBucketCooling) {
			t.Fatalf("连撞三次之后应该还在退避期,got %v", err)
		}
		neteaseReportSuccess(u)
		if err := neteaseThrottle(context.Background(), u); err != nil {
			t.Fatalf("成功之后冷却标记该被清掉,got %v", err)
		}
		if d, streak := neteaseReportRejected(u); streak != 1 || d != neteaseBlockCooldownBase {
			t.Errorf("清零后再次被拒 = (%v, %d), want (%v, 1)", d, streak, neteaseBlockCooldownBase)
		}
	})

	t.Run("成功过一次之后 SawSuccess 为真", func(t *testing.T) {
		reset()
		if neteaseSawSuccessNow() {
			t.Fatal("刚重置就报成功过")
		}
		neteaseReportRejected("https://music.163.com/api/search/get/web?type=1&s=a")
		if neteaseSawSuccessNow() {
			t.Error("只被拒过、没成功过,不该报成功")
		}
		neteaseReportSuccess("https://music.163.com/api/search/get?type=1&s=a")
		if !neteaseSawSuccessNow() {
			t.Error("成功过一次之后应该为真")
		}
	})
}

func TestNeteaseSearchEndpointOrder(t *testing.T) {
	if neteaseSearchEndpointPrimary != "https://music.163.com/api/search/get" {
		t.Errorf("首选端点 = %q,应当是 /api/search/get(实测零拒绝的那个桶)", neteaseSearchEndpointPrimary)
	}
	if neteaseSearchEndpointFallback != "https://music.163.com/api/search/get/web" {
		t.Errorf("兜底端点 = %q,应当保留 /api/search/get/web", neteaseSearchEndpointFallback)
	}
	if neteaseEndpointBucket(neteaseSearchEndpointPrimary) == neteaseEndpointBucket(neteaseSearchEndpointFallback) {
		t.Error("主备两个端点必须落在不同的限流桶,否则兜底那一跳形同虚设")
	}
}
