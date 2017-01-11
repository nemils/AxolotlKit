//
//  AxolotlKitLogging.h
//  AxolotlKit
//
//  Created by Jaroslaw Gajak on 11/01/17.
//  Copyright © 2017 Frederic Jacobs. All rights reserved.
//

#if AXO_LOGGING_DISABLED

//    #define AXOLogError(frmt, ...) ((void)0)
//    #define AXOLogWarn(frmt, ...) ((void)0)
//    #define AXOLogInfo(frmt, ...) ((void)0)
//    #define AXOLogDebug(frmt, ...) ((void)0)
//    #define AXOLogVerbose(frmt, ...) ((void)0)

#else

    #define AXO_LOG_LEVEL_DEF DDLogFlagDebug

    #if __has_include("CocoaLumberjack.h") || __has_include("CocoaLumberjack/CocoaLumberjack.h")
        #import <CocoaLumberjack/CocoaLumberjack.h>
    #else
        #define LOG_ASYNC_ENABLED YES
        #define LOG_MAYBE(async, lvl, flg, ctx, tag, fnct, frmt, ...) \
        do                                                        \
        {                                                         \
            if ((lvl & flg) == flg)                               \
            {                                                     \
                NSLog(frmt, ##__VA_ARGS__);                       \
            }                                                     \
        } while (0)
    #endif

// just to make it compile (those macros will be defined)
//#ifndef DDLogFlagError
//#define DDLogFlagError 0
//#endif
//
//#ifndef DDLogFlagWarning
//#define DDLogFlagWarning 1
//#endif
//
//#ifndef DDLogFlagInfo
//#define DDLogFlagInfo 2
//#endif

#ifndef DDLogFlagDebug
#define DDLogFlagDebug 3
#endif

//#ifndef DDLogFlagVerbose
//#define DDLogFlagVerbose 4
//#endif

//    #define AXOLogError(frmt, ...) LOG_MAYBE(NO,                    AXO_LOG_LEVEL_DEF, DDLogFlagError,      0, nil, __PRETTY_FUNCTION__, frmt, ##__VA_ARGS__)
//    #define AXOLogWarn(frmt, ...) LOG_MAYBE(LOG_ASYNC_ENABLED,      AXO_LOG_LEVEL_DEF, DDLogFlagWarning,    0, nil, __PRETTY_FUNCTION__, frmt, ##__VA_ARGS__)
//    #define AXOLogInfo(frmt, ...) LOG_MAYBE(LOG_ASYNC_ENABLED,      AXO_LOG_LEVEL_DEF, DDLogFlagInfo,       0, nil, __PRETTY_FUNCTION__, frmt, ##__VA_ARGS__)
    #define AXOLog(frmt, ...) LOG_MAYBE(LOG_ASYNC_ENABLED,     AXO_LOG_LEVEL_DEF, DDLogFlagDebug,      0, nil, __PRETTY_FUNCTION__, frmt, ##__VA_ARGS__)
//    #define AXOLogVerbose(frmt, ...) LOG_MAYBE(LOG_ASYNC_ENABLED,   AXO_LOG_LEVEL_DEF, DDLogFlagVerbose,    0, nil, __PRETTY_FUNCTION__, frmt, ##__VA_ARGS__)

#endif
