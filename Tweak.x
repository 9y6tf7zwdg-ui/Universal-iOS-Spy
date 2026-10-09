2026-10-09T23:24:35.5151080Z ##[group]Run export THEOS=/opt/theos
2026-10-09T23:24:35.5151340Z [36;1mexport THEOS=/opt/theos[0m
2026-10-09T23:24:35.5151540Z [36;1mmake package[0m
2026-10-09T23:24:35.5180880Z shell: /bin/bash -e {0}
2026-10-09T23:24:35.5181060Z ##[endgroup]
2026-10-09T23:24:40.8987050Z [0;36m==> [1;36mNotice:[m Build may be slow as Theos isn’t using all available CPU cores on this computer. Consider upgrading GNU Make: https://theos.dev/docs/parallel-building
2026-10-09T23:24:41.0032010Z [1;31m> [1;3;39mMaking all for tweak UniversalSpy…[m
2026-10-09T23:24:42.8369380Z [0;31m==> [1;39mPreprocessing Tweak.x…[m
2026-10-09T23:24:42.9323830Z [0;32m==> [1;39mCompiling Tweak.x (arm64)…[m
2026-10-09T23:24:46.5301820Z [1mTweak.x:209:64: [0m[0;1;31merror: [0m[1mmore '%' conversions than data arguments [-Werror,-Wformat-insufficient-args][0m
2026-10-09T23:24:46.5304200Z   209 |         NSLog(@"[VoicePlugin] 二次进入 sendSound，放行 %orig");[0m
2026-10-09T23:24:46.5304750Z       | [0;1;32m                                                       ~^
2026-10-09T23:24:46.6318850Z [0m1 error generated.
2026-10-09T23:24:46.6366290Z make[3]: *** [/Users/runner/work/Universal-iOS-Spy/Universal-iOS-Spy/.theos/obj/debug/arm64/Tweak.x.3db683f3.o] Error 1
2026-10-09T23:24:46.6367210Z rm /Users/runner/work/Universal-iOS-Spy/Universal-iOS-Spy/.theos/obj/debug/arm64/Tweak.x.m
2026-10-09T23:24:46.6370110Z make[2]: *** [/Users/runner/work/Universal-iOS-Spy/Universal-iOS-Spy/.theos/obj/debug/arm64/UniversalSpy.dylib] Error 2
2026-10-09T23:24:46.6372520Z make[1]: *** [internal-library-all_] Error 2
2026-10-09T23:24:46.6378030Z make: *** [UniversalSpy.all.tweak.variables] Error 2
2026-10-09T23:24:46.6398260Z ##[error]Process completed with exit code 2.