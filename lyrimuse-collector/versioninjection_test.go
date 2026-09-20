package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestClientVersionInjectionWiring(t *testing.T) {
	mainSrc, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("读 main.go: %v", err)
	}
	src := string(mainSrc)

	t.Run("clientVersion 必须是 var,不能是 const", func(t *testing.T) {

		if !regexp.MustCompile(`(?m)^var clientVersion\s*=`).MatchString(src) {
			t.Error("main.go 里找不到 `var clientVersion =` —— " +
				"-ldflags -X 只能注入 var,对 const 静默失效,注入链路会整条报废")
		}

		for _, line := range strings.Split(src, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "//") {
				continue
			}
			if regexp.MustCompile(`^clientVersion\s*=`).MatchString(trimmed) {
				t.Errorf("clientVersion 出现在 const block 里(%q)——必须是包级 var", trimmed)
			}
		}
	})

	t.Run("默认值必须是一眼假值,不能是具体版本号", func(t *testing.T) {

		m := regexp.MustCompile(`(?m)^var clientVersion\s*=\s*"([^"]*)"`).FindStringSubmatch(src)
		if m == nil {
			t.Fatal("解析不出 clientVersion 的默认值")
		}
		if regexp.MustCompile(`^\d+\.\d+`).MatchString(m[1]) {
			t.Errorf("clientVersion 默认值是 %q,像个真版本号 —— "+
				"发布构建靠 -ldflags 注入,默认值该是 dev 这种一眼假的值,"+
				"否则注入一旦失效就会谎报一个看着正常的过时版本(v1.3.0/v1.5.0 两次事故都是这个形态)", m[1])
		}
	})

	for _, script := range []struct{ path, name string }{
		{"../lyrimuse/build.sh", "App 打包(CI 发版也走它)"},
		{"build.sh", "本地只重建 collector"},
	} {
		t.Run("构建脚本带注入: "+script.name, func(t *testing.T) {
			b, err := os.ReadFile(script.path)
			if err != nil {
				t.Fatalf("读 %s: %v", script.path, err)
			}
			if !strings.Contains(string(b), "-X main.clientVersion=") {
				t.Errorf("%s 里没有 `-X main.clientVersion=` —— "+
					"这条路径构建出的 collector 会自报默认值,跟 App 版本对不上", script.path)
			}
		})
	}

	t.Run("App 构建脚本有产物级版本一致性闸", func(t *testing.T) {

		b, err := os.ReadFile("../lyrimuse/build.sh")
		if err != nil {
			t.Fatalf("读 build.sh: %v", err)
		}
		if !strings.Contains(string(b), "版本一致性") {
			t.Error("lyrimuse/build.sh 里找不到版本一致性校验 —— " +
				"光有 -ldflags 注入不够,注入失效是静默的,必须有一道跑产物问版本的闸")
		}
	})
}
