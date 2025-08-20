//
//  LinkedBlockingQueue.hpp
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/20/25.
//

#pragma once

#include <vector>
#include <list>
#include <mutex>
#include <shared_mutex>
#include <optional>
#include <atomic>
#include <limits>
#include <string>
#include <iostream>

#include "Semaphore.hpp"
#include "SharedRecursiveMutex.hpp"

namespace hs {
    template<typename T>
    class Node__class;

    template<typename T>
    using Node = std::shared_ptr<Node__class<T>>;

    template<typename T>
    class Node__class final {
    public:
        std::shared_ptr<std::optional<T>> item;
        std::optional<Node<T>> next;

        explicit Node__class() = default;

        static Node<T> new_Node() {
            return std::make_shared<Node__class>();
        }

        explicit Node__class(std::optional<T> item) {
            this->item = std::make_shared<std::optional<T>>(item);
            this->next = std::nullopt;
        }

        static Node<T> new_Node(std::optional<T> item) {
            return std::make_shared<Node__class>(item);
        }

        explicit Node__class(std::optional<T> item, std::optional<Node<T>> next) {
            this->item = std::make_shared<std::optional<T>>(item);
            this->next = next;
        }

        static Node<T> new_Node(std::optional<T> item, std::optional<Node<T>> next) {
            return std::make_shared<Node__class>(item, next);
        }

        explicit Node__class(T item, std::optional<Node<T>> next) {
            this->item = std::make_shared<std::optional<T>>(std::optional(item));
            this->next = next;
        }

        static Node<T> new_Node(T item, std::optional<Node<T>> next) {
            return std::make_shared<Node__class>(item, next);
        }

        explicit Node__class(std::shared_ptr<std::optional<T>> item, std::optional<Node<T>> next) {
            this->item = item;
            this->next = next;
        }

        static Node<T> new_Node(std::shared_ptr<std::optional<T>> item, std::optional<Node<T>> next) {
            return std::make_shared<Node__class>(item, next);
        }

        bool operator==(Node<T> rhs) {

            return ((item == rhs.item) && (next == rhs.next));
        }
    };

    template<typename T>
    class LinkedBlockingDeque {
    private:
        std::atomic<int> _count = 0;
        Semaphore nFilled;
        Semaphore nHoles;
        
        mutable mtx::shared_recursive_global_mutex mutex = mtx::shared_recursive_global_mutex();

    public:
        int capacity = std::numeric_limits<int>::max();
        std::optional<Node<T>> head;
        std::optional<Node<T>> last;
        
        /**
         * Returns the number of elements in this queue
         */
        int count() const {
            return _count;
        }


        int size() const {
            return _count;
        }

        /**
         * Returns the number of additional elements that this queue
         * can accept without blocking.
         */
        int remainingCapacity() const {
            return capacity - _count;
        }

        explicit LinkedBlockingDeque() {
            this->capacity = std::numeric_limits<int>::max();

            nFilled = Semaphore(0);
            nHoles = Semaphore(capacity);

            head = Node__class<T>::new_Node();
            last = head;
        }

        explicit LinkedBlockingDeque(const int capacity) {
            this->capacity = capacity;

            nFilled = Semaphore(0);
            nHoles = Semaphore(capacity);

            head = Node__class<T>::new_Node();
            last = head;
        }

        explicit LinkedBlockingDeque(std::vector<T> &elements, const int capacity = std::numeric_limits<int>::max()) {
            this->capacity = capacity;

            nFilled = Semaphore(0);
            nHoles = Semaphore(capacity);

            head = Node__class<T>::new_Node();
            last = head;

            int n = 0;

            for (const auto &e : elements) {
                if (n >= capacity) {
                    // Throw here
                }
                enqueue(Node__class<T>::new_Node(e));
                n += 1;
            }

            _count = n;
        }

        /**
         * Inserts the specific element at the tail of this queue,
         * waiting if necessary for space to become available.
         *
         * @param e The element to insert
         */
        void put(T e) {
            Node<T> node = Node__class<T>::new_Node(e);

            nHoles.wait();

            {
                // NOTE:- Java uses lockInterruptibly.
                std::unique_lock write_guard(mutex); // Exclusive single writer access

                enqueue(node);
            }

            nFilled.signal();
        }
        
        bool empty() {
            return size() == 0;
        }
        
        void putFirst(T e) {
            Node<T> node = Node__class<T>::new_Node(e);

            nHoles.wait();
            
            {
                // NOTE:- Java uses lockInterruptibly.
                std::unique_lock write_guard(mutex); // Exclusive single writer access
            
                if (head.has_value()) {
                    node->next = head.value();
                }

                head = node;

                _count += 1;
            }

            nFilled.signal();
            
        }
        

        /**
            A bool representing the empty status of the deque.

            @returns true if the deque has no elements
         */
        bool isEmpty() {
            return _count == 0;
        }

        /**
            Attempts to insert an element into the deque, if space is available.

            This method does not block while the deque is at full capacity, instead
            it will return false immediately.

            @returns True if element was inserted, false otherwise
         */
        bool offer(T e){
            bool offered = false;

            {
                std::unique_lock write_guard(mutex); // Exclusive single writer access

                if (remainingCapacity() > 0) {
                    Node<T> node = Node__class<T>::new_Node(e);
                    enqueue(node);
                    offered = true;
                }
            }

            if (offered) {
                nFilled.signal();
            }

            return offered;
        }

        bool contains(T e){
            bool hasValue = false;

            forEach([&](const T &t) {
                hasValue = hasValue || (t == e);
            });

            return hasValue;
        }
        
        bool remove(T e) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            std::optional<Node<T>> optionalCurrent = head;
            std::optional<Node<T>> optionalPred = std::nullopt;

            while (optionalCurrent.has_value()) {
                auto current = optionalCurrent.value();
                auto item = current->item;
                
                if (item != nullptr) {
                    if (current->item->has_value()) {
                        if (current->item->value() == e) {
                            unlink(optionalCurrent, optionalPred);
                            return true;
                        }
                    }
                }
                optionalPred = optionalCurrent;
                optionalCurrent = current->next;
            }
            
            return false;
        }

        /**
            Attempts to take a node's item from the head of the queue,
            returning null if there are no elements.

            Unlike take, this method will NOT block.
         */
        std::optional<T> poll() {
            std::optional<T> x = std::nullopt;

            {
                std::unique_lock write_guard(mutex); // Exclusive single writer access

                if (_count > 0) {
                    x = dequeue();
                }
            }
            
            if (x.has_value()) {
                nHoles.signal();
            }

            return x;
        }

        /**
         * Attempts to take a node's item from the queue.
         *
         * @returns: An optional element
         */
        std::optional<T> take() {
            std::optional<T> x;

            nFilled.wait();

            {
                std::unique_lock write_guard(mutex); // Exclusive single writer access

                x = dequeue();
            }
            
            nHoles.signal();

            return x;
        }

        /**
         * Removes every node from the queue.
         *
         * NOTE: The puts and takes are locked during this time.
         */
        void clear() {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            // Stupid workaround to capture reference
            std::optional<Node<T>> t = std::nullopt;
            std::optional<Node<T>> &p = t;
            std::optional<Node<T>> &h = head;

            while (h.has_value() && h.value()->next.has_value()) {
                if (h.has_value()) {
                    p = h.value()->next;
                    h.value()->next = h;
                } else {
                    p = {};
                }

                if (p.has_value()) {
                    p.value()->item = nullptr;
                }

                h = p;
            }

            head = last;

            _count = 0;

            nHoles.reset();
        }

        void unlink(std::optional<Node<T>> p, std::optional<Node<T>> pred) {
            std::unique_lock write_guard(mutex); // Exclusive single writer access

            if (p.has_value()) {
                p.value()->item = {};
            }

            if (pred.has_value()) {
                if (p.has_value()) {
                    pred.value()->next = p.value()->next;
                } else {
                    pred.value()->next = std::nullopt;
                }
            }

            if (last == p) {
                last = pred;
            }

            _count -= 1;

            if (_count < capacity) {
                signalNotFull();
            }
        }

    private:

        /**
         * Signals a waiting take.
         *
         * Called only from put/offer (which do not
         * otherwise ordinarily lock takeLock.)
         */
        void signalNotEmpty() {
            nHoles.signal();
        }

        /**
         * Signals a waiting put.
         *
         * Called only from take/poll.
         */
        void signalNotFull() {
            nFilled.signal();
        }

        /**
         * Links node at the end of the queue.
         *
         * @param node The node to be linked
         */
        void enqueue(Node<T> node) {

            if (last.has_value()) {
                last.value()->next = node;
            }

            last = node;

            _count += 1;
        }
        
    
        /**
         * Removes a node from the head of the queue.
         *
         * @returns: A Node
         */
        std::optional<T> dequeue() {
            std::optional<Node<T>> h = head;
            std::optional<Node<T>> first;

            if (h.has_value()) {
                first = h.value()->next;
            }

            head = first;

            std::optional<T> x;

            if (first.has_value()) {
                x = *(first.value()->item);
                first.value()->item = nullptr;
            }

            _count -= 1;

            return x;
        }

    public:
        template<typename F>
        void forEach(F fn){
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            auto optionalCurrent = head;
            while (optionalCurrent.has_value()) {
                auto current = optionalCurrent.value();
                auto item = current->item;

                if (item != nullptr) {
                    if (current->item->has_value()) {
                        fn(current->item->value());
                    }
                }

                optionalCurrent = current->next;
            }
        }

        template<typename F>
        std::optional<T> first(F fn){
            std::shared_lock read_guard(mutex); // Shared multi-reader access

            auto optionalCurrent = head;
            while (optionalCurrent.has_value()) {
                auto current = optionalCurrent.value();
                auto item = current->item;

                if (item != nullptr) {
                    if (current->item->has_value()) {
                        if (fn(current->item->value())) {
                            return current->item->value();
                        }
                    }
                }

                optionalCurrent = current->next;
            }

            return std::nullopt;
        }
    };
}

