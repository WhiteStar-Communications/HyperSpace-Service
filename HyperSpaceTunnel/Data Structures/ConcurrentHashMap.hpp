//
//  ConcurrentHashMap.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#pragma once

#include <cstdint>
#include <algorithm>
#include <iostream>
#include <functional>
#include <mutex>
#include <optional>
#include <vector>
#include <unordered_set>
#include <unordered_map>
#include <thread>
#include <initializer_list>

#include "HashBucket.hpp"
#include "SharedRecursiveMutex.hpp"

namespace hs {
    
    template<class K, class V, class Hasher, class Equals, class Allocator>
    class ConcurrentHashMap {
    private:
        const int default_capacity = std::max(16, (int)std::thread::hardware_concurrency());
        const int hashSize;
        std::vector<HashBucket<K,V>> hashMap = std::vector<HashBucket<K,V>>(ConcurrentHashMap::default_capacity);
        Hasher hashFn; //hash code generated using std::hash<k>
        
    public:
        mutable mtx::shared_recursive_global_mutex mutex = mtx::shared_recursive_global_mutex();
        
        ConcurrentHashMap()
            : hashSize(ConcurrentHashMap::default_capacity)
            , hashMap(std::vector<HashBucket<K,V>>(ConcurrentHashMap::default_capacity)) {
        }
        
        ConcurrentHashMap(int capacity)
            : hashSize(capacity)
            , hashMap(std::vector<HashBucket<K,V>>(capacity)) {
        }
        
        ~ConcurrentHashMap() = default;

        ConcurrentHashMap(const std::initializer_list<std::pair<K, V>> &oldMap)
            : hashSize(ConcurrentHashMap::default_capacity)
            , hashMap(std::vector<HashBucket<K,V>>(ConcurrentHashMap::default_capacity)) {

            for (const auto &entry : oldMap) {
                this->put_fast(entry.first, entry.second);
            }
        }
        
        ConcurrentHashMap(const std::unordered_map<K,V> &oldMap)
            : hashSize(ConcurrentHashMap::default_capacity)
            , hashMap(std::vector<HashBucket<K,V>>(ConcurrentHashMap::default_capacity)) {

            for (const auto &entry : oldMap) {
                this->put_fast(entry.first, entry.second);
            }
        }
        
        ConcurrentHashMap(std::unordered_map<K,V> &oldMap)
            : hashSize(ConcurrentHashMap::default_capacity)
            , hashMap(std::vector<HashBucket<K,V>>(ConcurrentHashMap::default_capacity)) {

            for (const auto &entry : oldMap) {
                this->put_fast(entry.first, entry.second);
            }
        }
        
        ConcurrentHashMap(std::unordered_map<K,V> *oldMap)
            : hashSize(ConcurrentHashMap::default_capacity)
            , hashMap(std::vector<HashBucket<K,V>>(ConcurrentHashMap::default_capacity)) {

            for (const auto &entry : oldMap) {
                this->put_fast(entry.first, entry.second);
            }
        }
        
        ConcurrentHashMap(ConcurrentHashMap &oldMap)
            : hashSize(oldMap.hashSize)
            , hashMap(oldMap.getDataSource()) {
        }
        
        ConcurrentHashMap(ConcurrentHashMap *oldMap)
            : hashSize(oldMap->hashSize)
            , hashMap(oldMap->getDataSource()) {
        }
        
        ConcurrentHashMap(const ConcurrentHashMap<K, V> &oldMap)
            : hashSize(oldMap.hashSize)
            , hashMap(oldMap.getDataSource()) {
        }
        
        std::vector<HashBucket<K,V>> getDataSource() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            auto temp_map = this->hashMap;
            return temp_map;
        }
        
        ConcurrentHashMap<K, V>& operator=(ConcurrentHashMap<K, V> &rhs) {
            //temporarily cast const hashSize as a regular int
            *const_cast<int*>(&hashSize) = rhs.hashSize;
            hashMap = rhs.getDataSource();
            return *this;
        }
        
        ConcurrentHashMap<K, V>& operator=(const ConcurrentHashMap<K, V> &rhs) {
            //temporarily cast const hashSize as a regular int
            *const_cast<int*>(&hashSize) = rhs.hashSize;
            hashMap = rhs.getDataSource();
            return *this;
        }
        
        ConcurrentHashMap<K, V>& operator=(ConcurrentHashMap<K, V> *rhs) {
            //temporarily cast const hashSize as a regular int
            *const_cast<int*>(&hashSize) = rhs->hashSize;
            hashMap = rhs->getDataSource();
            return *this;
        }

        bool operator==(const ConcurrentHashMap<K, V> &obj) {
            if (this->hashSize != obj.hashSize){
                return false;
            }
            for (int i = 0; i < hashSize; i++){
                if (!(this->hashMap[i] == obj.hashMap[i])){
                    return false;
                }
            }
            return true;
        }

        bool operator==(const ConcurrentHashMap<K, V> *obj) {
            if (this->hashSize != obj->hashSize){
                return false;
            }
            for (int i = 0; i < hashSize; i++){
                if (!(this->hashMap[i] == obj->hashMap[i])){
                    return false;
                }
            }
            return true;
        }

        bool operator==(ConcurrentHashMap<K, V> *obj) {
            if (this->hashSize != obj->hashSize){
                return false;
            }
            for (int i = 0; i < hashSize; i++){
                if (!(this->hashMap[i] == obj->hashMap[i])){
                    return false;
                }
            }
            return true;
        }

        std::optional<V> &operator[](const K &key) const {
            int hashValue = hashFn(key) % hashSize;
            if (hashMap[hashValue].containsKey(key)) {
                return hashMap[hashValue].myMap[key];
            }
            return {};
        }
        
        std::optional<V> &operator[](const K &key) {
            int hashValue = hashFn(key) % hashSize;
            if (hashMap[hashValue].containsKey(key)) {
                return hashMap[hashValue].myMap[key];
            }
            return {};
        }
        
        std::optional<V> &operator[](K &&key) {
            int hashValue = hashFn(key) % hashSize;
            
            if (hashMap[hashValue].containsKey(key)) {
                return hashMap[hashValue].myMap[key];
            }
            return {};
        }
        
        ////// READ ACCESS //////
        
        // The number of key-value mappings in this map
        size_t size() const {
            int count = 0;
            for (int i = 0; i < hashSize; i++){
                count += hashMap[i].size();
            }
            return count;
        }
        
        // true if this map contains no key-value mappings
        bool isEmpty() const {
            for (int i = 0; i < hashSize;i++){
                if (!hashMap[i].isEmpty()){
                    return false;
                }
            }
            return true;
        }
        
        // public V get(Object key)
        // the value to which the specified key is mapped, or null if this map contains no mapping for the key
        // For C++ gets a copy of the object, wrapped in std::optional<>
        std::optional<V> get(const K &key) const {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].get(key);
        }
        
        // experimental.  From C++ book example, return value in map or default value given.
        // This allows replacement for the above function get value
        // get get(key, nullptr);
        V get(const K &key, const V &value) const {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].get(key,value);
        }
        
        // Not java, extra interface. get actual value (copy), at() will throw std::out_of_range if not found
        V at(const K &key) const {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].at(key);
        }
        
        
        // true if and only if the specified object is a key in this table, as determined by the equals method
        // this might be added in c++ 20
        bool containsKey(const K &key) const {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].containsKey(key);
        }
        
        std::unordered_map<K, V> asUnorderedMap() const {
            std::unordered_map<K, V> map;
            std::vector<HashBucket<K,V>> tmpSource;

            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpSource = hashMap;
            }
            
            for (int i = 0; i < hashSize; i++) {
                const auto tmpMap = tmpSource[i].myMap;
                for (const auto &p: tmpMap) {
                    map[p.first] = p.second;
                }
            }
            
            return map;
        }
        
        // Returns an enumeration of the keys in this table.
        std::vector<K> keys() const {
            
            std::vector<K> keys_vec;
            keys_vec.reserve(size());

            for (int i = 0; i < hashSize; i++){
                std::vector<K> temp_vec = hashMap[i].keys();
                keys_vec.insert(keys_vec.end(), temp_vec.begin(), temp_vec.end());
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
            std::unordered_set<K> keys_set;
            keys_set.reserve(size());

            for (int i = 0; i < hashSize; i++){
                std::unordered_set<K> temp_set = hashMap[i].keySet();
                keys_set.insert(temp_set.begin(),temp_set.end());
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
            std::vector<V> mapped_vec;
            mapped_vec.reserve(size());

            for (int i = 0; i < hashSize; i++){
                std::vector<V> temp_vec = hashMap[i].values();
                mapped_vec.insert(mapped_vec.end(),temp_vec.begin(), temp_vec.end());
            }
            return mapped_vec;
        }
        
        // Returns an enumeration of the values in this table.
        std::vector<V> elements() {
            return this->values();
        }
        
        // Returns a Set view of the mappings contained in this map. The set is backed by the map,
        // so changes to the map are reflected in the set, and vice-versa. The set supports element removal,
        // which removes the corresponding mapping from the map,
        // via the Iterator.remove, Set.remove, removeAll, retainAll, and clear operations.
        // The view's iterators and spliterators are weakly consistent.
        // Returns: the set view
        std::vector<std::pair<K, V>> pairs() const {
            std::vector<std::pair<K, V>> pairs_vec;
            pairs_vec.reserve(size());

            for (int i = 0; i < hashSize; i++) {
                std::vector<std::pair<K, V>> temp_vec = hashMap[i].pairs();
                pairs_vec.insert(pairs_vec.end(),temp_vec.begin(),temp_vec.end());
            }
            return pairs_vec;
        }
        
        ////// WRITE ACCESS //////
        
        // Returns: the previous value associated with key, or null if there was no mapping for key
        std::optional<V> put(const K &key,
                                           const V &value) {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].put(key,value);
        }
        
        // experimental
        void put_fast(const K &key,
                      const V &value) {
            int hashValue = hashFn(key) % hashSize;
            hashMap[hashValue].put_fast(key,value);
        }
        
        //If the specified key is not already associated with a value, associate it with the given value.
        // Returns: the previous value associated with the specified key, or null if there was no mapping for the key
        std::optional<V> putIfAbsent(const K &key,
                                     const V &value) {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].putIfAbsent(key,value);
        }
        
        // Copies all of the mappings from the specified map to this one.
        // These mappings replace any mappings that this map had for any of the keys currently in the specified map.
        void putAll(const std::unordered_map<K, V> &map) {
            for (const auto &iter: map) {
                int hashValue = hashFn(iter.first) % hashSize;
                hashMap[hashValue].put_fast(iter.first,iter.second);
            }
            
        }

        void putAll(const ConcurrentHashMap<K, V> &src) {
            auto map = src.asUnorderedMap();
            putAll(map);
        }
        
        void putAll(ConcurrentHashMap<K, V> &src) {
            auto map = src.asUnorderedMap();
            putAll(map);
        }
        
        void putAll(ConcurrentHashMap<K, V> *src) {
            auto map = src->asUnorderedMap();
            putAll(map);
        }
        
        void retainAll(const std::unordered_set<K> &set) {
            for (const auto &p : keySet()) {
                if(set.find(p) == set.end()){
                    int hashValue = hashFn(p) % hashSize;
                    hashMap[hashValue].remove(p);
                }
            }
        }
        
        void retainAll(const ConcurrentHashMap &map) {
            for (const auto &p : keySet()) {
                if (!(map.containsKey(p))) {
                    int hashValue = hashFn(p) % hashSize;
                    hashMap[hashValue].remove(p);
                }
            }
        }
        
        void retainAll(ConcurrentHashMap *map) {
            for (const auto &p : keySet()) {
                if (!(map->containsKey(p))) {
                    int hashValue = hashFn(p) % hashSize;
                    hashMap[hashValue].remove(p);
                }
            }
        }
        
        // Removes the key (and its corresponding value) from this map. This method does nothing if the key is not in the map.
        // Returns: the previous value associated with key, or null if there was no mapping for key
        std::optional<V> remove(const K &key) {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].remove(key);
        }
        
        // Removes the entry for a key only if currently mapped to a given value.
        // Returns: true if the value was removed
        bool remove(const K &key, const V &value) {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].remove(key,value);
        }
        
        // whitestar might the removeALL() method, not sure of what overloads:  map, vector, set ?
        // create placeholder stubs for now
        
        // public boolean    removeAll(Collection<?> c)
        // Removes all of this collection's elements that are also contained in the specified
        // collection (optional operation).
        void removeAll(const std::unordered_map<K, V> &map) {
            for (const auto &iter : map){
                int hashValue = hashFn(iter.first) % hashSize;
                if(hashMap[hashValue].containsKey(iter.first)){
                    hashMap[hashValue].remove(iter.first);
                }
            }
        }
        
        void removeAll(const ConcurrentHashMap &map) {
            auto tempMap = map.asUnorderedMap();
            removeAll(tempMap);
        }
        
        void removeAll(ConcurrentHashMap *map) {
            auto tempMap = map->asUnorderedMap();
            removeAll(tempMap);
        }
        
        // Removes all of this collection's elements that are also contained in the specified
        // collection (optional operation).
        void removeAll(const std::vector<K> &keys) {
            for (const auto &k : keys) {
                int hashValue = hashFn(k) % hashSize;
                hashMap[hashValue].remove(k);
            }
        }
        
        // Removes all of this collection's elements that are also contained in the specified
        // collection (optional operation).
        void removeAll(const std::unordered_set<K> &set) {
            for (const auto &k : set) {
                int hashValue = hashFn(k) % hashSize;
                hashMap[hashValue].remove(k);
            }
        }
        
        std::optional<V> computeIfAbsentOptional(const K &k, std::function<std::optional<V>()> fn) {
            int hashValue = hashFn(k) % hashSize;
            return hashMap[hashValue].computeIfAbsentOptional(k,fn);
        }

        V computeIfAbsent(const K &k, std::function<V()> fn) {
            int hashValue = hashFn(k) % hashSize;
            return hashMap[hashValue].computeIfAbsent(k,fn);
        }
        
        void computeIfPresent(const K &k, std::function<std::optional<V>(V)> fn) {
            int hashValue = hashFn(k) % hashSize;
            return hashMap[hashValue].computeIfPresent(k, fn);
        }
        
        // Removes all of the mappings from this map.
        void clear() {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access

            for (int i = 0; i < hashSize;i++){
                hashMap[i].clear();
            }
        }
        
        // Returns true if this map maps one or more keys to the specified value.
        // Note: This method may require a full traversal of the map, and is much slower than method containsKey.
        bool containsValue(const V &value) const {
            for (int i = 0; i < hashSize;i++){
                for (const auto &[k, v] : hashMap[i].myMap) {
                    if (v == value) {
                        return true;
                    }
                }
            }
            return false;
        }
        
        // Returns the value to which the specified key is mapped,
        // or the given default value if this map contains no mapping for the key.
        // Returns: the mapping for the key, if present; else the default value
        V getOrDefault(const K &key, const V &defaultValue) const {
            int hashValue = hashFn(key) % hashSize;
            return hashMap[hashValue].getOrDefault(key,defaultValue);
        }
        
        // Compares the specified object with this map for equality. Returns true if the given object is
        // a map with the same mappings as this map. This operation may return misleading results if
        // either map is concurrently modified during execution of this method.
        // Returns: true if the specified object is equal to this map
        bool equals(ConcurrentHashMap<K, V> &obj) const {
            if(this->hashSize != obj.hashSize){
                return false;
            }

            std::vector<HashBucket<K,V>> tmpSource;

            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpSource = hashMap;
            }

            for (int i = 0; i < hashSize; i++) {
                const auto tmpMap = tmpSource[i].myMap;
                for (const auto &p: tmpMap) {
                    const auto objVal = obj.get(p.first);

                    if (!objVal.has_value()) {
                        return false;
                    }

                    if (objVal != p.second) {
                        return false;
                    }
                }
            }

            return true;
        }

        bool equals(const ConcurrentHashMap<K, V> &obj) const {
            if (this->hashSize != obj.hashSize) {
                return false;
            }

            std::vector<HashBucket<K,V>> tmpSource;

            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpSource = hashMap;
            }

            for (int i = 0; i < hashSize; i++) {
                const auto tmpMap = tmpSource[i].myMap;
                for (const auto &p: tmpMap) {
                    const auto objVal = obj.get(p.first);

                    if (!objVal.has_value()) {
                        return false;
                    }

                    if (objVal != p.second) {
                        return false;
                    }
                }
            }

            return true;
        }
        
        template<typename F>
        void forEach(F fn) {
            std::vector<HashBucket<K,V>> tmpSource;
            
            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpSource = hashMap;
            }
            
            for (int i = 0; i < hashSize; i++) {
                const auto tmpMap = tmpSource[i].myMap;
                for (const auto &p: tmpMap) {
                    fn(p.first, p.second);
                }
            }
        }
        
        template<typename F>
        void forEach(F fn) const {
            std::vector<HashBucket<K,V>> tmpSource;
            
            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpSource = hashMap;
            }
            
            for (int i = 0; i < hashSize; i++) {
                const auto tmpMap = tmpSource[i].myMap;
                for (const auto &p: tmpMap) {
                    fn(p.first, p.second);
                }
            }
        }
        
        ConcurrentHashMap filter(std::function<bool(std::pair<const K, V>)> &fn) {
            std::vector<HashBucket<K,V>> tmpSource;
            
            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpSource = hashMap;
            }
                        
            ConcurrentHashMap<K, V> newMap;
            
            for (int i = 0; i < hashSize;i++){
                const auto tmpMap = tmpSource[i].myMap;
                for (const auto &p : tmpMap) {
                    if (fn(p)) {
                        newMap.myMap[p.first] = p.second;
                    }
                }
            }
            
            return newMap;
        }
        
        std::string toString() {
            std::stringstream ss;
            ss << "{";
            
            size_t size = this->size();
            size_t count = 1;
            
            this->forEach([&](const auto &k, const auto &v) {
                ss << k << " : " << v;
                
                if (count++ != size) {
                    ss << ",";
                }
            });
            
            ss << "}";
            return ss.str();
        }
    };  // end: class ConcurrentHashMap()
    
    template <typename K, typename V>
    inline std::ostream &operator<<(std::ostream &out, ConcurrentHashMap<K,V> &obj) {
        out << "{";
        size_t size = obj.size();
        size_t count = 1;
        
        obj.forEach([&](const auto &k, const auto &v) {
            out << k << " : " << v;
            
            if (count++ != size) {
                out << ",";
            }
        });
        out << "}";
        return out;
    }

    template <typename K, typename V>
    inline std::ostream &operator<<(std::ostream &out, const ConcurrentHashMap<K,V> &obj) {
        out << "{";
        size_t size = obj.size();
        size_t count = 1;
        
        obj.forEach([&](const auto &k, const auto &v) {
            out << k << " : " << v;
            
            if (count++ != size) {
                out << ",";
            }
        });
        out << "}";
        return out;
    }
}

