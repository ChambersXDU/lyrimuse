package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestNetworkRoundIsRelativeNotCumulative(t *testing.T) {
	a0 := atomic.LoadInt32(&networkAttemptCount)
	f0 := atomic.LoadInt32(&networkFailureCount)
	t.Cleanup(func() {
		atomic.StoreInt32(&networkAttemptCount, a0)
		atomic.StoreInt32(&networkFailureCount, f0)
	})

	atomic.StoreInt32(&networkAttemptCount, 100)
	atomic.StoreInt32(&networkFailureCount, 0)
	if networkLooksDown() {
		t.Fatal("前提不对：全成功时累计判据不该报不通")
	}

	round := beginNetworkRound()
	atomic.AddInt32(&networkAttemptCount, 3)
	atomic.AddInt32(&networkFailureCount, 3)

	attempts, failures := round()
	if attempts != 3 || failures != 3 {
		t.Fatalf("差值算错: attempts=%d failures=%d", attempts, failures)
	}
	if !roundLooksNetworkDown(attempts, failures) {
		t.Error("这一轮全失败，应该判为网络不通")
	}

	if networkLooksDown() {
		t.Error("前提变了？累计判据这时本来就不该成立")
	}
}

func TestRoundLooksNetworkDownThreshold(t *testing.T) {
	cases := []struct {
		attempts, failures int32
		want               bool
	}{
		{0, 0, false},
		{2, 2, false},
		{3, 3, true},
		{5, 4, false},
		{10, 10, true},
	}
	for _, c := range cases {
		if got := roundLooksNetworkDown(c.attempts, c.failures); got != c.want {
			t.Errorf("attempts=%d failures=%d: got %v, want %v", c.attempts, c.failures, got, c.want)
		}
	}
}

func TestCollectorStatusWriteAndClear(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "status.json")

	saved := collectorStatusPath
	savedFlag := collectorStatusNetworkDown
	t.Cleanup(func() {
		collectorStatusMu.Lock()
		collectorStatusPath = saved
		collectorStatusNetworkDown = savedFlag
		collectorStatusMu.Unlock()
	})

	setCollectorStatusPath(path)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("刚设置路径时不该有文件（要清掉上次运行的残留）")
	}

	markCollectorNetworkDown()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("状态文件没写出来: %v", err)
	}
	var f collectorStatusFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("状态文件解析不了: %v", err)
	}
	if !f.NetworkDown || f.At == 0 {
		t.Errorf("内容不对: %+v", f)
	}

	clearCollectorNetworkDown()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("恢复之后文件该被删掉")
	}

	clearCollectorNetworkDown()
}

func TestCollectorStatusNoopWithoutPath(t *testing.T) {
	saved := collectorStatusPath
	savedFlag := collectorStatusNetworkDown
	t.Cleanup(func() {
		collectorStatusMu.Lock()
		collectorStatusPath = saved
		collectorStatusNetworkDown = savedFlag
		collectorStatusMu.Unlock()
	})
	collectorStatusMu.Lock()
	collectorStatusPath = ""
	collectorStatusNetworkDown = false
	collectorStatusMu.Unlock()

	markCollectorNetworkDown()
	clearCollectorNetworkDown()
	if collectorStatusNetworkDown {
		t.Error("没有路径时不该记下已写入状态")
	}
}
