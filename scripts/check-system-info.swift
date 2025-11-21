#!/usr/bin/env swift

import Cocoa
import Metal

print("=== システム情報取得 ===\n")

// OS情報
let osVersion = ProcessInfo.processInfo.operatingSystemVersion
print("【OS情報】")
print("osVersion: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")

// ハードウェアモデル
var size = 0
sysctlbyname("hw.model", nil, &size, nil, 0)
var model = [CChar](repeating: 0, count: size)
sysctlbyname("hw.model", &model, &size, nil, 0)
let hardwareModel = String(cString: model)

print("\n【ハードウェア】")
print("hardwareModel: \(hardwareModel)")

// CPU情報
var cpuBrandSize = 0
sysctlbyname("machdep.cpu.brand_string", nil, &cpuBrandSize, nil, 0)
var cpuBrand = [CChar](repeating: 0, count: cpuBrandSize)
sysctlbyname("machdep.cpu.brand_string", &cpuBrand, &cpuBrandSize, nil, 0)
let cpuBrandString = String(cString: cpuBrand)

var physicalCPU: Int = 0
var physicalCPUSize = MemoryLayout<Int>.size
sysctlbyname("hw.physicalcpu", &physicalCPU, &physicalCPUSize, nil, 0)

var logicalCPU: Int = 0
var logicalCPUSize = MemoryLayout<Int>.size
sysctlbyname("hw.logicalcpu", &logicalCPU, &logicalCPUSize, nil, 0)

print("\n【CPU】")
print("cpuBrand: \(cpuBrandString)")
print("physicalCPU: \(physicalCPU)")
print("logicalCPU: \(logicalCPU)")

// メモリ
var memSize: UInt64 = 0
var memSizeSize = MemoryLayout<UInt64>.size
sysctlbyname("hw.memsize", &memSize, &memSizeSize, nil, 0)
let memoryGB = Int(memSize / (1024 * 1024 * 1024))

print("\n【メモリ】")
print("memoryGB: \(memoryGB) GB")

// GPU情報
print("\n【GPU】")
if let device = MTLCreateSystemDefaultDevice() {
    print("Metal Default GPU: \(device.name)")
    print("  isLowPower: \(device.isLowPower)")
    print("  isRemovable: \(device.isRemovable)")
    print("  recommendedMaxWorkingSetSize: \((device.recommendedMaxWorkingSetSize / (1024*1024*1024))) GB")
}

// 全GPUデバイス
let devices = MTLCopyAllDevices()
print("\n全GPUデバイス数: \(devices.count)")
for (index, device) in devices.enumerated() {
    print("  GPU \(index): \(device.name)")
    print("    isLowPower: \(device.isLowPower)")
    print("    isRemovable: \(device.isRemovable)")
}
