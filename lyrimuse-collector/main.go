package main

import (
	"context"
	"flag"
	"fmt"
	_ "image/jpeg"
	_ "image/png"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

var clientVersion = "dev"

const (
	clientName = "lyrimuse"

	pollInterval      = 5 * time.Second
	playingNowRefresh = 60 * time.Second

	pnPendingMax = 8 * time.Second

	nullResumeGraceWindow = 60 * time.Second
	submitTimeout         = 15 * time.Second

	playingNowTimeout = 8 * time.Second
	singleTimeout     = 12 * time.Second
	singleMaxTries    = 2

	maxAccrualGapSecs = 60.0

	listenCapSecs = 240.0

	minTrackSecs = 30.0

	lyricBudgetBytes = 8000
)

func main() {

	installLogSink(isDaemonInvocation(os.Args))

	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(clientVersion)
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "search-lyrics" {
		runSearchLyricsCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "artist-avatars" {
		runArtistAvatarsCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		runHealthcheckCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "test-lyric-sources" {
		runTestLyricSourcesCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "regenerate-jyutping" {
		runRegenerateJyutpingCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "backfill-roma" {
		runBackfillRomaCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "dedupe-entries" {
		runDedupeEntriesCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "recheck-cover" {
		runRecheckCoverCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "recheck-instrumental" {
		runRecheckInstrumentalCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "retranslate-repeated" {
		runRetranslateRepeatedCLI(os.Args[2:])
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "resync-lyrics" {
		runResyncLyricsCLI(os.Args[2:])
		return
	}

	defaultConfigDir := configDir()
	if defaultConfigDir == "" {
		fatalExit(exitReasonHomeDirUnresolved, "cannot resolve home directory and LYRIMUSE_CONFIG_DIR is unset")
	}
	cfgPath := flag.String("config", filepath.Join(defaultConfigDir, "config.json"), "config file path")
	dryRun := flag.Bool("dry-run", false, "log submissions instead of calling ListenBrainz")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {

		fatalExit(exitReasonConfigUnreadable, "err=%v", err)
	}

	applyLogLevel(cfg.LogLevel)
	for _, issue := range cfg.loadIssues {

		log.Printf("config: %s", issue)
	}

	if cfg.Token == "" {
		log.Printf("no listenbrainz_token configured: ListenBrainz submission disabled, running locally only (media-control + lyrics/cover enrichment still work)")
	}

	if !acquireSingleInstanceLock(filepath.Dir(*cfgPath)) {
		logExit(exitReasonAlreadyRunning, "another collector instance holds the lock; exiting so shared caches are not clobbered, launchd KeepAlive will retry")
		os.Exit(0)
	}
	featureFlagsPath := filepath.Join(filepath.Dir(*cfgPath), clientName+"-features.json")
	features = loadFeatureFlags(featureFlagsPath)

	loadEnrichCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-cache.json"))

	loadArtistAliasCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-artist-alias-cache.json"))

	lyricsPinsPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lyrics-pins.json")

	loadMBPrimaryNameCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-artist-primary-cache.json"))

	loadAppleCatalogCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-apple-catalog-cache.json"))
	loadMotionCoverCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-motion-cover-cache.json"))

	loadAppleStorefrontArtistCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-apple-storefront-artist-cache.json"))

	loadAppleStorefrontTitleCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-apple-storefront-title-cache.json"))

	loadAppleAlbumHintCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-apple-album-hint-cache.json"))

	loadQQArtistNameCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-qq-artist-name-cache.json"))

	loadArtistIdentityCache(filepath.Join(filepath.Dir(*cfgPath), clientName+"-artist-identity-cache.json"))

	lyricsDir = features.LyricsDir
	if lyricsDir == "" {
		lyricsDir = filepath.Join(filepath.Dir(*cfgPath), "lyrics")
	}

	deviceArtworkDir = filepath.Join(filepath.Dir(*cfgPath), "artwork")

	artworkRelayURL, artworkRelayToken = cfg.StateRelayURL, cfg.StateRelayToken

	adoptEnrichRestore(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-restore.json"))
	migrateEnrichKeys()

	migrateBorrowedCoverAlbums()
	importLyricsFromFiles()

	migrateLyricEntities()

	invalidateStaleTranslations()

	migrateYRCWhitespaceTokens()

	migrateLyricTimelines()

	migrateManualPickMarks()
	exportLyricsFiles()

	setCollectorStatusPath(filepath.Join(filepath.Dir(*cfgPath), clientName+"-collector-status.json"))

	setEnrichCancelRequestPath(filepath.Join(filepath.Dir(*cfgPath), clientName+"-enrich-cancel-request.txt"))

	setPositionBiasPath(filepath.Join(filepath.Dir(*cfgPath), clientName+"-position-bias.json"))

	setLyricsFillPaths()
	weeklyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-weekly.json")
	dailyDigestPath = filepath.Join(filepath.Dir(*cfgPath), clientName+"-lb-daily.json")

	lb := &lbClient{root: cfg.APIRoot, token: cfg.Token, hc: &http.Client{}, dryRun: *dryRun, alerter: newAlerter(cfg.NotificationPlatform, cfg.NotificationWebhookURL, cfg.DingtalkSignSecret, cfg.FeishuSignSecret)}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("%s %s starting (bundles: %v, dry-run: %v)",
		clientName, clientVersion, cfg.BundleIDs, *dryRun)

	go sweepDeviceArtwork(ctx)
	err = run(ctx, cfg, lb)
	if err != nil && ctx.Err() == nil {
		fatalExit(exitReasonRunError, "err=%v", err)
	}

	if ctx.Err() != nil {
		logExit(exitReasonSignal, "context canceled by SIGTERM/SIGINT")
	} else {
		logExit(exitReasonRunReturned, "run returned without error")
	}
}
