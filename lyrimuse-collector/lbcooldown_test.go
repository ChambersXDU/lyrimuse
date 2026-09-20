package main

import (
	"net/http"
	"testing"
	"time"
)

func TestLbCooldownEscalatesOnRepeated429(t *testing.T) {
	c := &lbClient{}

	if c.coolingDown() {
		t.Fatal("初始状态不该在冷却中")
	}

	c.noteOutcome(false, http.StatusTooManyRequests)
	if !c.coolingDown() {
		t.Fatal("第一次 429 后应该立刻进入冷却")
	}
	first := c.cooldownUntil

	c.mu.Lock()
	c.cooldownUntil = time.Time{}
	c.mu.Unlock()
	c.noteOutcome(false, http.StatusTooManyRequests)
	second := c.cooldownUntil
	if !second.After(first) {
		t.Fatalf("第二次连续 429 的冷却期限应该比第一次晚(指数升级),first=%v second=%v", first, second)
	}

	c.mu.Lock()
	c.consecutive429 = 1000
	c.mu.Unlock()
	c.noteOutcome(false, http.StatusTooManyRequests)
	capped := time.Until(c.cooldownUntil)
	maxSchedule := lbCooldownSchedule[len(lbCooldownSchedule)-1]
	if capped > maxSchedule+time.Second {
		t.Fatalf("冷却时长应该封顶在 %v 附近,实际 %v", maxSchedule, capped)
	}
}

func TestLbCooldownClearsOnSuccess(t *testing.T) {
	c := &lbClient{}
	c.noteOutcome(false, http.StatusTooManyRequests)
	if !c.coolingDown() {
		t.Fatal("429 后应该在冷却中")
	}
	c.noteOutcome(true, http.StatusOK)
	if c.coolingDown() {
		t.Fatal("成功一次之后冷却应该清零,不能继续挡后面的请求")
	}
	c.mu.Lock()
	consecutive := c.consecutive429
	c.mu.Unlock()
	if consecutive != 0 {
		t.Fatalf("成功后 consecutive429 应该清零,实际 %d", consecutive)
	}
}

func TestLbCooldownIgnoresNon429Failures(t *testing.T) {
	c := &lbClient{}
	c.noteOutcome(false, http.StatusInternalServerError)
	if c.coolingDown() {
		t.Fatal("非 429 失败不该触发冷却")
	}
	c.noteOutcome(false, 0)
	if c.coolingDown() {
		t.Fatal("网络层错误(status=0)不该触发冷却")
	}
}
