// The MIT License (MIT)
//
// Copyright (c) 2015 Alexander Grebenyuk (github.com/kean).

import UIKit

public enum ImageContentMode {
    case AspectFill
    case AspectFit
}

public let ImageMaximumSize = CGSizeMake(CGFloat.max, CGFloat.max)

public typealias ImageTaskCompletion = (ImageResponse) -> Void

public let ImageManagerErrorDomain = "Nuke.ImageManagerErrorDomain"
public let ImageManagerErrorCancelled = -1
public let ImageManagerErrorUnknown = -2


// MARK: - ImageManaging

public protocol ImageManaging {
    func taskWithURL(URL: NSURL) -> ImageTask
    func taskWithRequest(request: ImageRequest) -> ImageTask
    func invalidateAndCancel()
    func removeAllCachedImages()
    func startPreheatingImages(requests: [ImageRequest])
    func stopPreheatingImages(requests: [ImageRequest])
    func stopPreheatingImages()
}

// MARK: - ImageManaging (Convenience)

public extension ImageManaging {
    func taskWithURL(URL: NSURL, completion: ImageTaskCompletion?) -> ImageTask {
        let task = self.taskWithURL(URL)
        if completion != nil { task.completion(completion!) }
        return task
    }
    
    func taskWithRequest(request: ImageRequest, completion: ImageTaskCompletion?) -> ImageTask {
        let task = self.taskWithRequest(request)
        if completion != nil { task.completion(completion!) }
        return task
    }
}


// MARK: - ImageManagerConfiguration

public struct ImageManagerConfiguration {
    public var dataLoader: ImageDataLoading
    public var decoder: ImageDecoding
    public var cache: ImageMemoryCaching?
    public var preheatingQueue = ImageTaskQueue()
    
    public init(dataLoader: ImageDataLoading, decoder: ImageDecoding = ImageDecoder(), cache: ImageMemoryCaching? = ImageMemoryCache()) {
        self.dataLoader = dataLoader
        self.decoder = decoder
        self.cache = cache
        self.preheatingQueue.maxConcurrentTaskCount = 2
    }
}


// MARK: - ImageManager

public class ImageManager: ImageManaging, ImageManagerLoaderDelegate, ImageTaskManaging {
    public let configuration: ImageManagerConfiguration
    
    private let imageLoader: ImageManagerLoader
    private var executingTasks = Set<ImageTaskInternal>()
    private var preheatingTasks = [ImageRequestKey: ImageTaskInternal]()
    private var preheatingQueue = ImageTaskQueue()
    private let lock = NSRecursiveLock()
    private var invalidated = false
    
    public init(configuration: ImageManagerConfiguration) {
        self.configuration = configuration
        self.imageLoader = ImageManagerLoader(configuration: configuration)
        self.imageLoader.delegate = self
    }
    
    // MARK: ImageManaging
    
    public func taskWithURL(URL: NSURL) -> ImageTask {
        return self.taskWithRequest(ImageRequest(URL: URL))
    }
    
    public func taskWithRequest(request: ImageRequest) -> ImageTask {
        return ImageTaskInternal(manager: self, request: request)
    }
    
    public func invalidateAndCancel() {
        self.performBlock {
            self.imageLoader.delegate = nil
            self.cancelTasks(Array(self.executingTasks))
            self.preheatingTasks.removeAll()
            self.preheatingQueue.cancelAllTasks()
            self.configuration.dataLoader.invalidate()
            self.invalidated = true
        }
    }
    
    public func removeAllCachedImages() {
        self.configuration.cache?.removeAllCachedImages()
        self.configuration.dataLoader.removeAllCachedImages()
    }
    
    // MARK: FSM (ImageTaskState)
    
    private func setState(state: ImageTaskState, forTask task: ImageTaskInternal)  {
        if task.isValidNextState(state) {
            self.transitionStateAction(task.state, toState: state, task: task)
            task.state = state
            self.enterStateAction(state, task: task)
        }
    }
    
    private func transitionStateAction(fromState: ImageTaskState, toState: ImageTaskState, task: ImageTaskInternal) {
        if fromState == .Running && toState == .Cancelled {
            self.imageLoader.stopLoadingForTask(task)
        }
    }
    
    private func enterStateAction(state: ImageTaskState, task: ImageTaskInternal) {
        if state == .Running {
            if let response = self.imageLoader.cachedResponseForRequest(task.request) {
                task.response = ImageResponse.Success(response.image, ImageResponseInfo(fastResponse: true, userInfo: response.userInfo))
                self.setState(.Completed, forTask: task)
            } else {
                self.executingTasks.insert(task)
                self.didUpdateExecutingTaskCount()
                self.imageLoader.startLoadingForTask(task)
            }
        }
        if state == .Cancelled {
            task.response = ImageResponse.Failure(NSError(domain: ImageManagerErrorDomain, code: ImageManagerErrorCancelled, userInfo: nil))
        }
        if state == .Completed || state == .Cancelled {
            self.executingTasks.remove(task)
            self.didUpdateExecutingTaskCount()
            
            let completions = task.completions
            self.dispatchBlock {
                assert(task.response != nil)
                for completion in completions {
                    completion(task.response!)
                }
            }
        }
    }
    
    private func didUpdateExecutingTaskCount() {
        self.preheatingQueue.suspended = self.executingTasks.count > self.preheatingQueue.maxConcurrentTaskCount
    }
    
    private func dispatchBlock(block: (Void) -> Void) {
        NSThread.isMainThread() ? block() : dispatch_async(dispatch_get_main_queue(), block)
    }
    
    // MARK: ImageManaging (Preheating)
    
    public func startPreheatingImages(requests: [ImageRequest]) {
        self.performBlock {
            for request in requests {
                let key = self.imageLoader.preheatingKeyForRequest(request)
                if self.preheatingTasks[key] == nil {
                    let task = ImageTaskInternal(manager: self, request: request)
                    task.completion { [weak self] _ in
                        self?.preheatingTasks[key] = nil
                    }
                    self.preheatingTasks[key] = task
                    self.preheatingQueue.addTask(task)
                }
            }
        }
    }
    
    public func stopPreheatingImages(requests: [ImageRequest]) {
        self.performBlock {
            self.cancelTasks(requests.flatMap {
                return self.preheatingTasks[self.imageLoader.preheatingKeyForRequest($0)]
            })
        }
    }
    
    public func stopPreheatingImages() {
        self.performBlock {
            self.cancelTasks(Array(self.preheatingTasks.values))
        }
    }
    
    private func cancelTasks(tasks: [ImageTaskInternal]) {
        tasks.forEach { self.setState(.Cancelled, forTask: $0) }
    }
    
    // MARK: ImageManagerLoaderDelegate
    
    internal func imageLoader(imageLoader: ImageManagerLoader, imageTask: ImageTask, didUpdateProgressWithCompletedUnitCount completedUnitCount: Int64, totalUnitCount: Int64) {
        imageTask.progress.totalUnitCount = totalUnitCount
        imageTask.progress.completedUnitCount = completedUnitCount
    }
    
    internal func imageLoader(imageLoader: ImageManagerLoader, imageTask: ImageTask, didCompleteWithImage image: UIImage?, error: ErrorType?) {
        let imageTaskInterval = imageTask as! ImageTaskInternal
        if image != nil {
            imageTaskInterval.response = ImageResponse.Success(image!, ImageResponseInfo(fastResponse: false))
        } else {
            imageTaskInterval.response = ImageResponse.Failure(error ?? NSError(domain: ImageManagerErrorDomain, code: ImageManagerErrorUnknown, userInfo: nil))
        }
        self.performBlock {
            self.setState(.Completed, forTask: imageTaskInterval)
        }
    }
    
    // MARK: ImageTaskManaging
    
    private func resumeManagedTask(task: ImageTaskInternal) {
        self.performBlock {
            self.setState(.Running, forTask: task)
        }
    }
    
    private func cancelManagedTask(task: ImageTaskInternal) {
        self.performBlock {
            self.setState(.Cancelled, forTask: task)
        }
    }
    
    private func addCompletion(completion: ImageTaskCompletion, forTask task: ImageTaskInternal) {
        self.performBlock {
            if task.state == .Completed || task.state == .Cancelled {
                dispatchBlock {
                    assert(task.response != nil)
                    completion(task.response!)
                }
            } else {
                task.completions.append(completion)
            }
        }
    }
    
    // MARK: Misc
    
    private func performBlock(@noescape block: Void -> Void) {
        self.lock.lock()
        if !self.invalidated {
            block()
        }
        self.lock.unlock()
    }
}


// MARK: - ImageTaskInternal

private protocol ImageTaskManaging {
    func resumeManagedTask(task: ImageTaskInternal)
    func cancelManagedTask(task: ImageTaskInternal)
    func addCompletion(completion: ImageTaskCompletion, forTask task: ImageTaskInternal)
}

private class ImageTaskInternal: ImageTask {
    let manager: ImageTaskManaging
    var completions = [ImageTaskCompletion]()
    
    init(manager: ImageTaskManaging, request: ImageRequest) {
        self.manager = manager
        super.init(request: request)
    }
    
    override func resume() -> Self {
        self.manager.resumeManagedTask(self)
        return self
    }
    
    override func cancel() -> Self {
        self.manager.cancelManagedTask(self)
        return self
    }
    
    override func completion(completion: ImageTaskCompletion) -> Self {
        self.manager.addCompletion(completion, forTask: self)
        return self
    }
    
    func isValidNextState(state: ImageTaskState) -> Bool {
        switch (self.state) {
        case .Suspended: return (state == .Running || state == .Cancelled)
        case .Running: return (state == .Completed || state == .Cancelled)
        default: return false
        }
    }
}
