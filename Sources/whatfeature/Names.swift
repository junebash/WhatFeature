import ArgumentParser

/// ArgumentParser's `@Flag` and WhatFeatureCore's `Flag` share a name. Declarations in this module win over
/// imported ones, so `@Flag` here means ArgumentParser's; write the model as `WhatFeatureCore.Flag`.
typealias Flag = ArgumentParser.Flag
