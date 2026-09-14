import Foundation

// =====================================================================
// libIOReport — the private framework powermetrics reads, usable with no
// root and no entitlement.
//
// WHY dlopen AND NOT -lIOReport: the CLT SDK does ship a linker stub
// (usr/lib/libIOReport.tbd) so `-lIOReport` links cleanly today. But a hard
// link against a private library means that if Apple ever drops a symbol the
// app fails to LAUNCH. Resolving through dlopen/dlsym means the same event
// degrades to "power metrics unavailable". The dylib is in the dyld shared
// cache, so dlopen succeeds even though the path does not exist on disk.
//
// Every function here takes only pointers and plain integers, so the C ABI
// and Swift's coincide. Never add one that passes a struct by value.
// =====================================================================

typealias IOReportSubscriptionRef = UnsafeMutableRawPointer

final class IOReportLib {

    typealias CopyChannelsInGroupFn = @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias MergeChannelsFn = @convention(c)
        (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    typealias CreateSubscriptionFn = @convention(c)
        (UnsafeRawPointer?, CFMutableDictionary,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> IOReportSubscriptionRef?
    typealias CreateSamplesFn = @convention(c)
        (IOReportSubscriptionRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDeltaFn = @convention(c)
        (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias SimpleGetIntegerValueFn = @convention(c) (CFDictionary, Int32) -> Int64

    let copyChannelsInGroup: CopyChannelsInGroupFn
    let mergeChannels: MergeChannelsFn
    let createSubscription: CreateSubscriptionFn
    let createSamples: CreateSamplesFn
    let createSamplesDelta: CreateSamplesDeltaFn
    let channelGetGroup: ChannelStringFn
    let channelGetSubGroup: ChannelStringFn
    let channelGetChannelName: ChannelStringFn
    let channelGetUnitLabel: ChannelStringFn
    let simpleGetIntegerValue: SimpleGetIntegerValueFn

    /// nil when the library or any required symbol is missing. The caller
    /// must then report power as unavailable, not as zero.
    static let shared: IOReportLib? = IOReportLib()

    private init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let a = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroupFn.self),
              let b = sym("IOReportMergeChannels", MergeChannelsFn.self),
              let c = sym("IOReportCreateSubscription", CreateSubscriptionFn.self),
              let d = sym("IOReportCreateSamples", CreateSamplesFn.self),
              let e = sym("IOReportCreateSamplesDelta", CreateSamplesDeltaFn.self),
              let f = sym("IOReportChannelGetGroup", ChannelStringFn.self),
              let g = sym("IOReportChannelGetSubGroup", ChannelStringFn.self),
              let h = sym("IOReportChannelGetChannelName", ChannelStringFn.self),
              let i = sym("IOReportChannelGetUnitLabel", ChannelStringFn.self),
              let j = sym("IOReportSimpleGetIntegerValue", SimpleGetIntegerValueFn.self)
        else { return nil }
        copyChannelsInGroup = a
        mergeChannels = b
        createSubscription = c
        createSamples = d
        createSamplesDelta = e
        channelGetGroup = f
        channelGetSubGroup = g
        channelGetChannelName = h
        channelGetUnitLabel = i
        simpleGetIntegerValue = j
    }
}
