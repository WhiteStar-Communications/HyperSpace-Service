//
//  Dictionary+Extension.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 9/18/25.
//

import Foundation

extension Dictionary where Value == [String] {
    /// Removes the given values from existing arrays.
    /// Deletes the key if the array becomes empty.
    /// Returns true if anything was actually removed.
    mutating func removeValues(from other: [Key: [String]]) -> Bool {
        var didChange = false
        for (key, valuesToRemove) in other {
            guard var existing = self[key] else { continue }
            
            let beforeCount = existing.count
            existing.removeAll { valuesToRemove.contains($0) }
            
            if existing.count != beforeCount {
                didChange = true
                if existing.isEmpty {
                    self.removeValue(forKey: key)
                } else {
                    self[key] = existing
                }
            }
        }
        return didChange
    }
}
