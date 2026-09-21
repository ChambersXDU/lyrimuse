import LyrimuseCore
import Foundation

print("lyrics-parsing")
runLyricsParsingTests()

print("lyrics-resolver")
runLyricsResolverTests()

print("sync-engine")
runSyncEngineTests()

if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("FAILED (\(failures))")
    exit(1)
}
