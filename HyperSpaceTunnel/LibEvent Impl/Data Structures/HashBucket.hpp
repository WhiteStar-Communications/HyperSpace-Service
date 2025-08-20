//
//  HashBucket.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#pragma once

#include <cstdint>
#include <iostream>
#include <functional>
#include <mutex>
#include <optional>
#include <unordered_set>
#include <unordered_map>
#include "SharedRecursiveMutex.hpp"

namespace hs {
    
    template<class K, class V, class Hasher = std::hash<K>, class Equals = std::equal_to<K>,class Allocator = std::allocator<std::pair<const K, V>>>
    class ConcurrentHashMap;
    
    template<class K, class V, class Hasher = std::hash<K>, class Equals = std::equal_to<K>,class Allocator = std::allocator<std::pair<const K, V>>>
    class HashBucket{
    private:
        std::unordered_map<K, V, Hasher, Equals, Allocator> myMap;
        friend class ConcurrentHashMap<K,V>;
        
    public:
        // public in case want to let users lock for long reads or iterations
        mutable mtx::shared_recursive_global_mutex mutex = mtx::shared_recursive_global_mutex();
        
        HashBucket() {}
        
        HashBucket(const HashBucket &old) {
            old.copyIntoMap(myMap);
        }
        
        HashBucket(const HashBucket *old) {
            old->copyIntoMap(myMap);
        }

        explicit HashBucket(const std::unordered_map<K, V> *old) {
            for (const auto &p : old) {
                myMap[p.first] = p.second;
            }
        }

        explicit HashBucket(const std::unordered_map<K, V> &old) {
            for (const auto &p : old) {
                myMap[p.first] = p.second;
            }
        }
        
        HashBucket<K, V, Hasher, Equals, Allocator>& operator=(HashBucket<K, V, Hasher, Equals, Allocator> &rhs) {
            myMap = rhs.getDataSource();
            return *this;
        }
        
        HashBucket<K, V, Hasher, Equals, Allocator>& operator=(const HashBucket<K, V, Hasher, Equals, Allocator> &rhs) {
            myMap = rhs.getDataSource();
            return *this;
        }
        
        void copyIntoMap(std::unordered_map<K, V> &map) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            for (const auto &p : myMap) {
                map[p.first] = p.second;
            }
        }
        
        std::unordered_map<K, V, Hasher, Equals, Allocator> getDataSource() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            std::unordered_map<K, V, Hasher, Equals, Allocator> map;
            
            for (const auto &p : myMap) {
                map[p.first] = p.second;
            }
            
            return map;
        }
        
        bool operator==(const HashBucket &map) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
                        
            for (const auto &[k, v] : myMap) {
                auto optValue = map.get(k);
                
                if (!optValue.has_value()) {
                    if (optValue.value() != v) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
            
        }
        
        bool operator==(const HashBucket *map) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            for (const auto &[k, v] : myMap) {
                auto optValue = map->get(k);
                
                if (!optValue.has_value()) {
                    if (optValue.value() != v) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        }
        
        bool operator==(std::unordered_map<K, V> *map) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            for (const auto &[k, v] : map) {
                auto it = myMap.find(k);
                
                if (it != myMap.end()) {
                    if (myMap.at(k) != v) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        }
        
        std::optional<V> &operator[](const K &key) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            if (containsKey(key)) {
                return myMap[key];
            }
            return {};
        }
        
        std::optional<V> &operator[](K &&key) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            if (containsKey(key)) {
                return myMap[key];
            }
            return {};
        }
        
        ////// READ ACCESS //////
        
        // The number of key-value mappings in this map
        size_t size() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            return myMap.size();  // assume atomic, no locking needed
        }
        
        // true if this map contains no key-value mappings
        bool isEmpty() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            return myMap.empty();  // assume atomic, no locking needed
        }
        
        
        // public V get(Object key)
        // the value to which the specified key is mapped, or null if this map contains no mapping for the key
        // For C++ gets a copy of the object, wrapped in std::optional<>
        std::optional<V> get(const K &key) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
                       
            auto it = myMap.find(key);
            if (it != myMap.end()) {
                return (*it).second;
            }
            return std::nullopt;
        }
        
        // experimental.  From C++ book example, return value in map or default value given.
        // This allows replacement for the above function get value
        // get get(key, nullptr);
        V get(const K &key, const V &value) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            auto it = myMap.find(key);
            if (it != myMap.end()) {
                return (*it).second;
            }
            return value;
        }
        
        // Not java, extra interface. get actual value (copy), at() will throw std::out_of_range if not found
        V at(const K &key) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            return myMap.at(key);
        }
        
        
        // true if and only if the specified object is a key in this table, as determined by the equals method
        // this might be added in c++ 20
        bool containsKey(const K &key) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            return (myMap.find(key) != myMap.end());
        }
        
        // Returns an enumeration of the keys in this table.
        std::vector<K> keys() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            std::vector<K> keys_vec;
            keys_vec.reserve(myMap.size());
            for (auto const &it : myMap) {
                keys_vec.push_back(it.first);
            }
            return keys_vec;
        }
        
        // Returns a Set view of the keys contained in this map.
        // The set is backed by the map, so changes to the map are reflected in the set,
        // and vice-versa. The set supports element removal,
        // which removes the corresponding mapping from this map,
        // via the Iterator.remove, Set.remove, removeAll, retainAll, and clear operations.
        // It does not support the add or addAll operations.
        // The view's iterators and spliterators are weakly consistent.
        // Returns: the set view
        std::unordered_set<K> keySet() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            std::unordered_set<K> keys_set;
            keys_set.reserve(myMap.size());
            for (auto const &it : myMap) {
                keys_set.insert(it.first);
            }
            return keys_set;
        }
        
        // Returns a Collection view of the values contained in this map.
        // The collection is backed by the map, so changes to the map are reflected in the collection,
        // and vice-versa. The collection supports element removal, which removes the corresponding mapping from this map,
        // via the Iterator.remove, Collection.remove, removeAll, retainAll, and clear operations.
        // It does not support the add or addAll operations.
        // The view's iterators and spliterators are weakly consistent.
        // Returns: the collection view
        std::vector<V> values() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            std::vector<V> mapped_vec;
            mapped_vec.reserve(myMap.size());
            for (auto const &it : myMap) {
                mapped_vec.push_back(it.second);
            }
            return mapped_vec;
        }
        
        // Returns an enumeration of the values in this table.
        std::vector<V> elements() {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            return this->values();
        }
        
        // Returns a Set view of the mappings contained in this map. The set is backed by the map,
        // so changes to the map are reflected in the set, and vice-versa. The set supports element removal,
        // which removes the corresponding mapping from the map,
        // via the Iterator.remove, Set.remove, removeAll, retainAll, and clear operations.
        // The view's iterators and spliterators are weakly consistent.
        // Returns: the set view
        std::vector<std::pair<K, V>> pairs() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            std::vector<std::pair<K, V>> pairs_vec;
            pairs_vec.reserve(myMap.size());
            for (auto const &it : myMap) {
                pairs_vec.push_back(it);
            }
            return pairs_vec;
        }
        
        
        // copied from copy on write
        // iterators
        typename std::unordered_map<K, V>::iterator begin() {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            return myMap.begin();
        }
        
        typename std::unordered_map<K, V>::iterator end() {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            return myMap.end();
        }

        ////// WRITE ACCESS //////
        
        // Returns: the previous value associated with key, or null if there was no mapping for key
        [[nodiscard]] std::optional<V> put(const K &key,
                                           const V &value) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            auto it = myMap.find(key);
            myMap[key] = value;
            if (it != myMap.end()) {
                return (*it).second;
            }
            return std::nullopt;
        }
        
        // experimental
        void put_fast(const K &key,
                      const V &value) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            // always replace the value in the map
            myMap[key] = value;
        }
        
        //If the specified key is not already associated with a value, associate it with the given value.
        // Returns: the previous value associated with the specified key, or null if there was no mapping for the key
        std::optional<V> putIfAbsent(const K &key,
                                     const V &value) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            auto it = myMap.find(key);
            if (it != myMap.end()) {
                return (*it).second;
            } else {
                myMap[key] = value;
                return std::nullopt;
            }
        }
        
        
        // Copies all of the mappings from the specified map to this one.
        // These mappings replace any mappings that this map had for any of the keys currently in the specified map.
        void putAll(const std::unordered_map<K, V> &map) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &[k, v] : map) {
                myMap[k] = v;
            }
        }
        
        void putAll(HashBucket<K, V> &src) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &e : src.getDataSource()) {
                myMap[e.first] = e.second;
            }
        }
        
        void putAll(HashBucket<K, V> *src) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &e : src->getDataSource()) {
                myMap[e.first] = e.second;
            }
        }
        
        void retainAll(const std::unordered_set<K> &set) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &p : keySet()) {
                // Check to see if the pair's key exists in the set passed in
                if (set.find(p) == set.end()) {
                    myMap.erase(p);
                }
            }
        }
        
        void retainAll(HashBucket &map) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &p : keySet()) {
                // Check to see if the pair's key exists in the set passed in
                if (!(map.containsKey(p))) {
                    myMap.erase(p);
                }
            }
        }
        
        void retainAll(HashBucket *map) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &p : keySet()) {
                // Check to see if the pair's key exists in the set passed in
                if (!(map->containsKey(p))) {
                    myMap.erase(p);
                }
            }
        }
        
        // Removes the key (and its corresponding value) from this map. This method does nothing if the key is not in the map.
        // Returns: the previous value associated with key, or null if there was no mapping for key
        std::optional<V> remove(const K &key) {
            // slight different than below, as want the original value back, so have to query it
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            auto it = myMap.find(key);
            std::optional<V> optionalValue = std::nullopt;
            
            if (it != myMap.end()) {
                optionalValue = std::make_optional<V>((*it).second);
                myMap.erase(key);
                return optionalValue;
            }
            return optionalValue;
        }
        
        // Removes the entry for a key only if currently mapped to a given value.
        // Returns: true if the value was removed
        bool remove(const K &key,
                    const V &value) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            auto it = myMap.find(key);
            if ((it != myMap.end()) && ((*it).second == value)) {
                myMap.erase(key);
                return true;
            }
            return false;
        }
        
        // whitestar might the removeALL() method, not sure of what overloads:  map, vector, set ?
        // create placeholder stubs for now
        
        // public boolean    removeAll(Collection<?> c)
        // Removes all of this collection's elements that are also contained in the specified
        // collection (optional operation).
        void removeAll(const std::unordered_map<K, V> &map) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &[k, v] : map) {
                auto it = myMap.find(k);
                
                if (it != myMap.end()) {
                    myMap.erase(k);
                }
            }
        }
        
        void removeAll(HashBucket &map) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &e : map.getDataSource()) {
                auto it = myMap.find(e.first);
                
                if (it != myMap.end()) {
                    myMap.erase(e.first);
                }
            }
        }
        
        void removeAll(HashBucket *map) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &e : map->getDataSource()) {
                auto it = myMap.find(e.first);
                
                if (it != myMap.end()) {
                    myMap.erase(e.first);
                }
            }
        }
        
        // Removes all of this collection's elements that are also contained in the specified
        // collection (optional operation).
        void removeAll(std::vector<K> keys) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &k : keys) {
                myMap.erase(k);
            }
        }
        
        // Removes all of this collection's elements that are also contained in the specified
        // collection (optional operation).
        void removeAll(const std::unordered_set<K> &set) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            for (const auto &k : set) {
                myMap.erase(k);
            }
        }
        
        std::optional<V> computeIfAbsentOptional(const K &k, std::function<std::optional<V>()> fn) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            std::optional<V> v = get(k);
            
            if (v.has_value()) {
                return v.value();
            } else {
                std::optional<V> nV = fn();

                if (nV.has_value()) {
                    put_fast(k, nV.value());
                }
                return nV;
            }
        }

        V computeIfAbsent(const K &k, std::function<V()> fn) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            std::optional<V> v = get(k);

            if (v.has_value()) {
                return v.value();
            } else {
                V nV = fn();
                put_fast(k, nV);
                return nV;
            }
        }
        
        void computeIfPresent(const K &k, std::function<std::optional<V>(V)> fn) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            std::optional<V> v = get(k);
            if (v.has_value()) {
                std::optional<V> newValue = fn(v.value());
                
                if (newValue.has_value()) {
                    myMap[k] = newValue.value();
                } else {
                    myMap.erase(k);
                }
            }
        }
        
        // Removes all of the mappings from this map.
        void clear() {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            myMap.clear();
        }
        
        // Returns true if this map maps one or more keys to the specified value.
        // Note: This method may require a full traversal of the map, and is much slower than method containsKey.
        bool containsValue(const V &value) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            for (const auto &[k, v] : myMap) {
                if (v == value) {
                    return true;
                }
            }
            return false;
        }
        
        // Returns the value to which the specified key is mapped,
        // or the given default value if this map contains no mapping for the key.
        // Returns: the mapping for the key, if present; else the default value
        V getOrDefault(const K &key, const V &defaultValue) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            auto it = myMap.find(key);
            if (it != myMap.end()) {
                return (*it).second;
            } else {
                return defaultValue;
            }
        }
        
        // Compares the specified object with this map for equality. Returns true if the given object is
        // a map with the same mappings as this map. This operation may return misleading results if
        // either map is concurrently modified during execution of this method.
        // Returns: true if the specified object is equal to this map
        bool equals(HashBucket<K, V> &map) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            for (const auto &[k, v] : myMap) {
                auto optValue = map.get(k);
                
                if (!optValue.has_value()) {
                    if (optValue.value() != v) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        }

        bool equals(const HashBucket<K, V> &map) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            for (const auto &[k, v] : myMap) {
                auto optValue = map.get(k);

                if (!optValue.has_value()) {
                    if (optValue.value() != v) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        }
        
        int hashCode() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            int hash = 0;
            
            for (const auto &p : myMap) {
                hash += std::hash<V>()(p.second);
            }
            
            return hash;
        }
        
        template<typename F>
        void forEach(F fn) {
            std::unordered_map<K, V, Hasher, Equals, Allocator> tmpMap;
            
            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpMap = std::unordered_map<K, V, Hasher, Equals, Allocator>(myMap);
            }
            
            for (const auto &p: tmpMap) {
                fn(p.first, p.second);
            }
        }
        
        template<typename F>
        void forEach(F fn) const {
            std::unordered_map<K, V, Hasher, Equals, Allocator> tmpMap;
            
            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpMap = std::unordered_map<K, V, Hasher, Equals, Allocator>(myMap);
            }
            
            for (const auto &p: tmpMap) {
                fn(p.first, p.second);
            }
        }
        
        HashBucket filter(std::function<bool(std::pair<const K, V>)> &fn) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            HashBucket<K, V> newMap;
            
            for (const auto &p : myMap) {
                if (fn(p)) {
                    newMap[p.first] = p.second;
                }
            }
            
            return newMap;
        }
    };  // end: class HashBucket()

    template <typename K, typename V>
    inline std::ostream &operator<<(std::ostream &out, HashBucket<K,V> &obj) {
        out << "{";
        size_t size = obj.size();
        size_t count = 1;
        
        obj.forEach([&](const auto k, const auto &v) {
            out << k << " : " << v;
            
            if (count++ != size) {
                out << ",";
            }
        });
        out << "}";
        return out;
    }

    template <typename K, typename V>
    inline std::ostream &operator<<(std::ostream &out, const HashBucket<K,V> &obj) {
        out << "{";
        size_t size = obj.size();
        size_t count = 1;
        
        obj.forEach([&](const auto k, const auto &v) {
            out << k << " : " << v;
            
            if (count++ != size) {
                out << ",";
            }
        });
        out << "}";
        return out;
    }
}





