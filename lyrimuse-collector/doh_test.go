package main

import "testing"

func TestDoHParseAnswerKeepsOnlyARecords(t *testing.T) {
	body := []byte(`{"Status":0,"Answer":[
		{"name":"apic-appmobile.musixmatch.com","type":5,"TTL":300,"data":"elb.amazonaws.com."},
		{"name":"elb.amazonaws.com","type":1,"TTL":60,"data":"44.212.146.46"},
		{"name":"elb.amazonaws.com","type":1,"TTL":60,"data":"52.5.55.223"}
	]}`)
	got := dohParseAnswer(body)
	if len(got) != 2 || got[0] != "44.212.146.46" || got[1] != "52.5.55.223" {
		t.Fatalf("只该留下两条 A 记录, got %v", got)
	}
}

func TestDoHParseAnswerRejectsNonIPv4(t *testing.T) {
	body := []byte(`{"Answer":[
		{"type":28,"data":"2606:4700::6810:d76"},
		{"type":1,"data":"1.2.3.4"},
		{"type":1,"data":"不是地址"}
	]}`)
	got := dohParseAnswer(body)
	if len(got) != 1 || got[0] != "1.2.3.4" {
		t.Fatalf("只该留下合法的 IPv4, got %v", got)
	}
}

func TestDoHParseAnswerHandlesGarbage(t *testing.T) {
	for _, body := range []string{"", "{}", "not json", `{"Answer":[]}`, `{"Answer":null}`} {
		if got := dohParseAnswer([]byte(body)); len(got) != 0 {
			t.Errorf("%q 应该返回空, got %v", body, got)
		}
	}
}

func TestDoHShouldResolveOnlyListedHosts(t *testing.T) {
	yes := []string{
		"apic-appmobile.musixmatch.com",
		"apic-desktop.musixmatch.com",
		"APIC-DESKTOP.MUSIXMATCH.COM",
		"apic-desktop.musixmatch.com.",
	}
	for _, h := range yes {
		if !dohShouldResolve(h) {
			t.Errorf("%q 应该走 DoH", h)
		}
	}
	no := []string{
		"music.163.com",
		"lrclib.net",
		"c.y.qq.com",
		"",

		"evil-musixmatch.com",
		"musixmatch.com.attacker.example",
	}
	for _, h := range no {
		if dohShouldResolve(h) {
			t.Errorf("%q 不该走 DoH", h)
		}
	}
}
