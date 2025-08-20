//
//  ArrayList.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

/*
 * Copyright (c) 2021, WhiteStar Communications, Inc.
 * All rights reserved.
 *
 */
//

#pragma once

#include <vector>
#include <optional>
#include <iostream>
#include <algorithm>
#include <memory>
//#include "ordered_set.h"
#include <unordered_set>
#include <stdexcept>
#include <initializer_list>
#include <functional>

#include "SharedRecursiveMutex.hpp"

namespace hs {
    template<typename T>
    class ArrayList {
    public:
        typedef std::function<bool (const T&, const T&)> Sorter;
        std::vector<T> array;

        mutable mtx::shared_recursive_global_mutex mutex = mtx::shared_recursive_global_mutex();

        ~ArrayList() = default;

        ArrayList() : array(std::vector<T>()) {}

        ArrayList(const std::initializer_list<T> &src)
            : array(std::vector<T>(src.begin(), src.end())) {
        }

        ArrayList(std::vector<T> *src)
            : array(std::vector<T>(src->begin(), src->end())) {
        }

        ArrayList(const std::vector<T> &src)
            : array(std::vector<T>(src.begin(), src.end())) {
        }

        ArrayList(std::vector<T> &src)
            : array(std::vector<T>(src.begin(), src.end())) {
        }

        ArrayList(std::vector<T> &&src)
            : array(std::vector<T>(src.begin(), src.end())) {
        }
        
        ArrayList(const ArrayList &src)
            : array(src.getInternalDataSource()) {
        }
        
        ArrayList(const ArrayList *src)
            : array(src->getInternalDataSource()) {
        }
        
        ArrayList(T t) {
            array.emplace_back(t);
        }
        
        ArrayList(T *t) {
            array.emplace_back(t);
        }
        
        ArrayList(T &t) {
            array.emplace_back(t);
        }

        ArrayList(const ArrayList &src,
                  const Sorter &sort) {
            array = std::vector<T>(src.begin(), src.end());
            std::sort(array.begin(), array.end(), sort);
        }

        ArrayList(const std::unordered_set<T> &src,
                  const Sorter &sort) {
            array = std::vector<T>(src.begin(), src.end());
            std::sort(array.begin(), array.end(), sort);
        }

        ArrayList(std::unordered_set<T> &&src,
                  const Sorter &sort) {
            array = std::vector<T>(src.begin(), src.end());
            std::sort(array.begin(), array.end(), sort);
        }
        
        ArrayList<T>& operator=(ArrayList<T> &rhs) {
            array = rhs.getInternalDataSource();
            return *this;
        }
        
        ArrayList<T>& operator=(const ArrayList<T> &rhs) {
            array = rhs.getInternalDataSource();
            return *this;
        }
    
    public:
        std::vector<T> getInternalDataSource() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            return array;
        }

        /**
         *  Resizes the ArrayList, keeping only up to the specified
         *  number of elements from the head.
         *
         *  If newSize is greater than the current container, no change occurs.
         *
         *  @param newSize The desired number of elements to keep
         *  @returns true if the ArrayList changed as a result
         */
        bool keepFirst(const int &newSize) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            if (newSize > array.size()) {
                return false;
            } else {
                array.resize(newSize);
                return true;
            }
        }
        
        bool contains(const T &t) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            
            auto it = std::find(array.begin(), array.end(), t);
            
            return (it != array.end());
        }

        void insert(const T &t, const int &index) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            if (index == 0 && array.size() == 0) {
                array.emplace_back(t);
            } else if (index >= 0 && index < array.size()) {
                array.insert(array.begin() + index, t);
            } else {
                throw std::out_of_range("ArrayList cannot insert index " + std::to_string(index));
            }
        }
        
        bool addIfAbsent(const T &t) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            // note: this does not use is the internal class iterator, which is probably good
            auto it = std::find(array.begin(), array.end(), t);
            if (it != array.end()) {
                return false;  // found in array
            }
            array.emplace_back(t);
            return true;
        }

        void add(const T &t) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            array.emplace_back(t);
        }
        
        bool addAll(std::vector<T> *src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            bool changed = false;

            for (const auto &e : src) {
                changed = true;
                array.emplace_back(e);
            }
            
            return changed;
        }
        
        
        bool addAll(std::vector<T> &src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            bool changed = false;

            for (const auto &e : src) {
                changed = true;
                array.emplace_back(e);
            }
            
            return changed;
        }

        bool addAll(ArrayList<T> &&src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            auto size = array.size();

            src.forEach([&](const T &t) {
                array.emplace_back(t);
            });

            return (array.size() != size);
        }
        
        
        bool addAll(ArrayList<T> &src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            auto size = array.size();
            
            src.forEach([&](const T &t) {
                array.emplace_back(t);
            });

            return (array.size() != size);
        }

        bool addAll(const ArrayList<T> &src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            auto size = array.size();

            src.forEach([&](const T &t) {
                array.emplace_back(t);
            });

            return (array.size() != size);
        }
        
        bool addAll(ArrayList<T> *src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            auto size = array.size();
            
            src->forEach([&](const T &t) {
                array.emplace_back(t);
            });
            
            return (array.size() != size);
        }
        
        bool addAllAbsent(std::vector<T> src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            bool changed = false;

            for (const auto &e : src) {
                auto it = std::find(array.begin(), array.end(), e);
                
                if (it == array.end()) {
                    array.emplace_back(e);
                    changed = true;
                }
            }

            return changed;
        }
        
        bool addAllAbsent(ArrayList<T> &src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            auto size = array.size();
            
            src.forEach([&](const T &t) {
                auto it = std::find(array.begin(), array.end(), t);
                
                if (it == array.end()) {
                    array.emplace_back(t);
                }
            });
            
            return (array.size() != size);
        }
        
        bool addAllAbsent(ArrayList<T> *src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            auto size = array.size();
            
            src->forEach([&](const T &t) {
                auto it = std::find(array.begin(), array.end(), t);
                
                if (it == array.end()) {
                    array.emplace_back(t);
                }
            });
            
            return (array.size() != size);
        }
        
        bool removeAll(ArrayList *src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            bool changed = false;
            
            src->forEach([&](const T &t) {
                auto it = std::find(array.begin(), array.end(), t);
                
                if (it != array.end()) {
                    changed = true;
                    array.erase(it);
                }
            });
            
            return changed;
        }

        bool removeAll(const ArrayList &src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            bool changed = false;

            src.forEach([&](const T &t) {
                auto it = std::find(array.begin(), array.end(), t);

                if (it != array.end()) {
                    changed = true;
                    array.erase(it);
                }
            });

            return changed;
        }
        
        bool removeAll(ArrayList &src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            bool changed = false;
            
            src.forEach([&](const T &t) {
                auto it = std::find(array.begin(), array.end(), t);
                
                if (it != array.end()) {
                    changed = true;
                    array.erase(it);
                }
            });

            return changed;
        }

        bool removeAll(ArrayList &&src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            bool changed = false;

            src.forEach([&](const T &t) {
                auto it = std::find(array.begin(), array.end(), t);

                if (it != array.end()) {
                    changed = true;
                    array.erase(it);
                }
            });

            return changed;
        }
        
        bool removeAll(std::vector<T> &src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            bool changed = false;

            for (const auto &e : src) {
                auto it = std::find(array.begin(), array.end(), e);
                
                if (it != array.end()) {
                    changed = true;
                    array.erase(it);
                }
            }
            
            return changed;
        }
        
        bool removeAll(std::vector<T> *src) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            bool changed = false;

            for (const auto &e : src) {
                auto it = std::find(array.begin(), array.end(), e);
                
                if (it != array.end()) {
                    changed = true;
                    array.erase(it);
                }
            }

            return changed;
        }

        std::optional<T> removeAt(int index) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            if (index >= 0 && index < array.size()) {
                auto retVal = array.at(index);
                array.erase(array.begin() + index);
                return retVal;
            } else {
                return std::nullopt;
            }
        }
        
        std::optional<T> remove(const T &t) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            auto it = std::find(array.begin(), array.end(), t);
            
            if (it != array.end()) {
                auto retVal = array.at(std::distance(array.begin(), it));
                array.erase(it);
                return retVal;
            }
            return std::nullopt;
        }
        
        std::optional<T> remove(T &t) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            
            auto it = std::find(array.begin(), array.end(), t);
            
            if (it != array.end()) {
                auto retVal = array.at(std::distance(array.begin(), it));
                array.erase(it);

                return retVal;
            }
            return std::nullopt;
        }
        
        void clear() {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            array = std::vector<T>();
        }
        
        void sort(const Sorter &sort) {
            std::unique_lock write_guard(mutex); // Exclusive single-writer access
            
            std::sort(array.begin(), array.end(), sort);
        }
        
        ArrayList<T> sorted(const Sorter &sort) {
            std::vector<T> tmp;
            
            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmp = array;
            }
                        
            return ArrayList<T>(tmp, sort);
        }
        
        template<typename F>
        void forEach(F fn) const {
            std::vector<T> tmpVector;

            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpVector = getInternalDataSource();
            }

            for (const auto &e : tmpVector) {
                fn(e);
            }
        }

        template<typename F>
        std::optional<T> first(F fn) const {
            std::vector<T> tmpVector;

            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpVector = getInternalDataSource();
            }

            for (const auto &e : tmpVector) {
                if (fn(e)) {
                    return e;
                }
            }
            return std::nullopt;
        }

        template<typename F>
        bool containsWhere(F fn) const {
            std::vector<T> tmpVector;

            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpVector = getInternalDataSource();
            }

            for (const auto &e : tmpVector) {
                if (fn(e)) {
                    return true;
                }
            }
            return false;
        }

        template<typename F>
        ArrayList<T> filtered(F fn) const {
            std::vector<T> tmpVector;

            {
                std::shared_lock read_guard(mutex); // Shared multi-reader access
                tmpVector = getInternalDataSource();
            }

            tmpVector.erase(
                std::remove_if(tmpVector.begin(),
                               tmpVector.end(),
                               [&fn](const T &e) {
                    return fn(e);
                }), tmpVector.end());

            return ArrayList<T>(tmpVector);
        }

        template<typename F>
        void filter(F fn) const {
            std::shared_lock write_guard(mutex); // Shared multi-reader access

            array.erase(
                std::remove_if(array.begin(),
                               array.end(),
                               [&fn](const T &e) {
                    return fn(e);
                }), array.end());
        }

        void reverse() {
            std::unique_lock write_guard(mutex); // Exclusive single writer access
            std::reverse(array.begin(), array.end());
        }
               
        std::optional<T> get(int index) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            if (index >= 0 && index < array.size()) {
                return array.at(index);
            } else {
                return std::nullopt;
            }
        }
        
        T &operator[](int index) {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (index >= 0 && index < array.size()) {
                return array.at(index);
            } else {
                throw std::out_of_range("ArrayList does not contain index " + std::to_string(index));
            }
         }
        
        bool operator==(const ArrayList &obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj.array.size()) {
                return false;
            }

            for (const auto &e : array) {
                if (!obj.contains(e)) {
                    return false;
                }
            }

            return true;
        }

        bool operator!=(const ArrayList &obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj.array.size()) {
                return true;
            }

            for (const auto &e : array) {
                if (!obj.contains(e)) {
                    return true;
                }
            }

            return false;
        }
        
        bool operator==(ArrayList &obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj.array.size()) {
                return false;
            }

            for (const auto &e : array) {
                if (!obj.contains(e)) {
                    return false;
                }
            }

            return true;
        }

        bool operator!=(ArrayList &obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj.array.size()) {
                return true;
            }

            for (const auto &e : array) {
                if (!obj.contains(e)) {
                    return true;
                }
            }

            return false;
        }
        
        bool operator==(const ArrayList *obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj->array.size()) {
                return false;
            }

            for (const auto &e : (array)) {
                if (!obj->contains(e)) {
                    return false;
                }
            }

            return true;
        }

        bool operator!=(const ArrayList *obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj->array.size()) {
                return true;
            }

            for (const auto &e : (array)) {
                if (!obj->contains(e)) {
                    return true;
                }
            }

            return false;
        }
        
        bool operator==(ArrayList *obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj->array.size()) {
                return false;
            }

            for (const auto &e : (array)) {
                if (!obj->contains(e)) {
                    return false;
                }
            }

            return true;
        }

        bool operator!=(ArrayList *obj) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != obj->array.size()) {
                return true;
            }

            for (const auto &e : (array)) {
                if (!obj->contains(e)) {
                    return true;
                }
            }

            return false;
        }
        
        bool operator==(std::vector<T> &src) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != src.size()) {
                return false;
            }

            for (const auto &e : array) {
                auto it = std::find(src.begin(), src.end(), e);

                if (it == src.end()) {
                    return false;
                }
            }

            return true;
        }

        bool operator!=(std::vector<T> &src) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access


            if (array.size() != src.size()) {
                return true;
            }

            for (const auto &e : array) {
                auto it = std::find(src.begin(), src.end(), e);

                if (it == src.end()) {
                    return true;
                }
            }

            return false;
        }
        
        bool operator==(std::vector<T> *src) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != src->size()) {
                return false;
            }

            for (const auto &e : (array)) {
                auto it = std::find(src->begin(), src->end(), e);

                if (it == src->end()) {
                    return false;
                }
            }

            return true;
        }

        bool operator!=(std::vector<T> *src) const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            if (array.size() != src->size()) {
                return true;
            }

            for (const auto &e : (array)) {
                auto it = std::find(src->begin(), src->end(), e);

                if (it == src->end()) {
                    return true;
                }
            }

            return false;
        }

        // iterators
        typename std::vector<T>::iterator begin() noexcept {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            return array.begin();
        }

        typename std::vector<T>::const_iterator begin() const noexcept {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            return array.begin();
        }

        typename std::vector<T>::iterator end() noexcept {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            return array.end();
        }

        typename std::vector<T>::const_iterator end() const noexcept {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            return array.end();
        }
        
        bool empty() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            return array.empty();
        }
        
        bool isEmpty() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            return array.empty();
        }
        
        size_t size() const {
            std::shared_lock read_guard(mutex); // Shared multi-reader access
            return array.size();
        }
        
        std::string toString() {
            std::stringstream ss;
            ss << "[";
            
            size_t size = this->size();
            size_t count = 1;

            this->forEach([&](auto &e){
                ss << e;

                if (count++ != size) {
                    ss << ",";
                }
            });
            
            ss << "]";
            return ss.str();
        }
    };
    
    template <typename T>
    inline std::ostream &operator<<(std::ostream &out, ArrayList<T> &obj) {
        out << "[";
        size_t size = obj.size();
        size_t count = 1;

        obj.forEach([&](auto &e){
            out << e;

            if (count++ != size) {
                out << ",";
            }
        });
        out << "]";
        return out;
    }

    template <typename T>
    inline std::ostream &operator<<(std::ostream &out, const ArrayList<T> &obj) {
        out << "[";
        size_t size = obj.size();
        size_t count = 1;

        obj.forEach([&](auto &e){
            out << e;

            if (count++ != size) {
                out << ",";
            }
        });
        out << "]";
        return out;
    }
}


