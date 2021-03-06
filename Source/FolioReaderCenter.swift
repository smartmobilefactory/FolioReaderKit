//
//  FolioReaderCenter.swift
//  FolioReaderKit
//
//  Created by Heberti Almeida on 08/04/15.
//  Copyright (c) 2015 Folio Reader. All rights reserved.
//

import UIKit
import ZFDragableModalTransition

/// Protocol which is used from `FolioReaderCenter`s.
@objc public protocol FolioReaderCenterDelegate: class {

    /// Notifies that a page appeared. This is triggered is a page is chosen and displayed.
    ///
    /// - Parameter page: The appeared page
    @objc optional func pageDidAppear(_ page: FolioReaderPage)

    /// Passes and returns the HTML content as `String`. Implement this method if you want to modify the HTML content of a `FolioReaderPage`.
    ///
    /// - Parameters:
    ///   - page: The `FolioReaderPage`.
    ///   - htmlContent: The current HTML content as `String`.
    /// - Returns: The adjusted HTML content as `String`. This is the content which will be loaded into the given `FolioReaderPage`.
    @objc optional func htmlContentForPage(_ page: FolioReaderPage, htmlContent: String) -> String
}

/// The base reader class
open class FolioReaderCenter: UIViewController, UICollectionViewDelegate, UICollectionViewDataSource {

    /// This delegate receives the events from the current `FolioReaderPage`s delegate.
    open weak var delegate: FolioReaderCenterDelegate?

    /// This delegate receives the events from current page
    open weak var pageDelegate: FolioReaderPageDelegate?

    open var readerContainer: FolioReaderContainer

    /// The current visible page on reader
    open fileprivate(set) var currentPage: FolioReaderPage?

    var collectionView: UICollectionView!
    let collectionViewLayout = UICollectionViewFlowLayout()
    var loadingView: UIActivityIndicatorView!
    var pages: [String]!
    var totalPages: Int = 0
    var tempFragment: String?
    var animator: ZFModalTransitionAnimator!
    var pageIndicatorView: FolioReaderPageIndicator?
    var pageIndicatorHeight: CGFloat = 20
    var recentlyScrolled = false
    var recentlyScrolledDelay = 2.0 // 2 second delay until we clear recentlyScrolled
    var recentlyScrolledTimer: Timer!
    var scrollScrubber: ScrollScrubber?
    var activityIndicator = UIActivityIndicatorView()
    var isScrolling = false
    var pageScrollDirection = ScrollDirection()
    var nextPageNumber: Int = 0
    var previousPageNumber: Int = 0
    var currentPageNumber: Int = 0
    var pageWidth: CGFloat = 0.0
    var pageHeight: CGFloat = 0.0

    fileprivate var screenBounds: CGRect!
    fileprivate var pointNow = CGPoint.zero
    fileprivate var pageOffsetRate: CGFloat = 0
    fileprivate var tempReference: FRTocReference?
    fileprivate var isFirstLoad = true
    fileprivate var currentWebViewScrollPositions = [Int: CGPoint]()
    fileprivate var currentOrientation: UIInterfaceOrientation?

    fileprivate var book: FRBook {
        return self.readerContainer.book
    }

    fileprivate var readerConfig: FolioReaderConfig {
        return self.readerContainer.readerConfig
    }

    // MARK: - Init

    init(withContainer readerContainer: FolioReaderContainer) {
        self.readerContainer = readerContainer
        super.init(nibName: nil, bundle: Bundle.frameworkBundle())

        self.initialization()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("This class doesn't support NSCoding.")
    }

    /**
     Common Initialization
     */
    fileprivate func initialization() {

        if (self.readerConfig.hideBars == true) {
            self.pageIndicatorHeight = 0
        }

        self.totalPages = self.book.spine.spineReferences.count

        // Loading indicator
        let style: UIActivityIndicatorViewStyle = self.readerContainer.folioReader.isNight(.white, .gray)
        loadingView = UIActivityIndicatorView(activityIndicatorStyle: style)
        loadingView.hidesWhenStopped = true
        loadingView.startAnimating()
        self.view.addSubview(loadingView)
    }

    // MARK: - View life cicle

    override open func viewDidLoad() {
        super.viewDidLoad()

        screenBounds = self.view.frame
        setPageSize(UIApplication.shared.statusBarOrientation)

        // Layout
        collectionViewLayout.sectionInset = UIEdgeInsets.zero
        collectionViewLayout.minimumLineSpacing = 0
        collectionViewLayout.minimumInteritemSpacing = 0
        collectionViewLayout.scrollDirection = .direction(withConfiguration: self.readerConfig)

        let background = self.readerContainer.folioReader.isNight(self.readerConfig.nightModeBackground, UIColor.white)
        view.backgroundColor = background

        // CollectionView
        collectionView = UICollectionView(frame: screenBounds, collectionViewLayout: collectionViewLayout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.isPagingEnabled = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.backgroundColor = background
        collectionView.decelerationRate = UIScrollViewDecelerationRateFast
        enableScrollBetweenChapters(scrollEnabled: true)
        view.addSubview(collectionView)

        // Activity Indicator
        self.activityIndicator.activityIndicatorViewStyle = .gray
        self.activityIndicator.hidesWhenStopped = true
        self.activityIndicator = UIActivityIndicatorView(frame: CGRect(x: self.view.frame.width/2, y: self.view.frame.height/2, width: 30, height: 30))
        self.activityIndicator.backgroundColor = UIColor.gray
        self.view.addSubview(self.activityIndicator)
        self.view.bringSubview(toFront: self.activityIndicator)

        if #available(iOS 10.0, *) {
            collectionView.isPrefetchingEnabled = false
        }

        // Register cell classes
        collectionView?.register(FolioReaderPage.self, forCellWithReuseIdentifier: kReuseCellIdentifier)

        // Configure navigation bar and layout
        automaticallyAdjustsScrollViewInsets = false
        extendedLayoutIncludesOpaqueBars = true
        configureNavBar()

        // Page indicator view
        if (self.readerConfig.hidePageIndicator == false) {
            let frame = self.frameForPageIndicatorView()
            pageIndicatorView = FolioReaderPageIndicator(frame: frame, readerConfig: self.readerConfig, folioReader: self.readerContainer.folioReader)
            if let pageIndicatorView = pageIndicatorView {
                view.addSubview(pageIndicatorView)
            }
        }

        self.scrollScrubber = ScrollScrubber(frame: self.frameForScrollScrubber(), withReaderContainer: self.readerContainer)
        self.scrollScrubber?.delegate = self
        if let scrollScrubber = scrollScrubber {
            view.addSubview(scrollScrubber.slider)
        }
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        configureNavBar()

        // Update pages
        pagesForCurrentPage(currentPage)
        pageIndicatorView?.reloadView(updateShadow: true)
    }

    override open func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        screenBounds = view.frame
        loadingView.center = view.center

        setPageSize(UIApplication.shared.statusBarOrientation)
        updateSubviewFrames()
    }

    // MARK: Layout

    /**
     Enable or disable the scrolling between chapters (`FolioReaderPage`s). If this is enabled it's only possible to read the current chapter. If another chapter should be displayed is has to be triggered programmatically with `changePageWith`.

     - parameter scrollEnabled: `Bool` which enables or disables the scrolling between `FolioReaderPage`s.
     */
    open func enableScrollBetweenChapters(scrollEnabled: Bool) {
        self.collectionView.isScrollEnabled = scrollEnabled
    }

    fileprivate func updateSubviewFrames() {
        self.pageIndicatorView?.frame = self.frameForPageIndicatorView()
        self.scrollScrubber?.frame = self.frameForScrollScrubber()
    }

    fileprivate func frameForPageIndicatorView() -> CGRect {
        return CGRect(x: 0, y: view.frame.height-pageIndicatorHeight, width: view.frame.width, height: pageIndicatorHeight)
    }

    fileprivate func frameForScrollScrubber() -> CGRect {
        let scrubberY: CGFloat = ((self.readerConfig.shouldHideNavigationOnTap == true || self.readerConfig.hideBars == true) ? 50 : 74)
        return CGRect(x: self.pageWidth + 10, y: scrubberY, width: 40, height: (self.pageHeight - 100))
    }

    func configureNavBar() {
        let navBackground = self.readerContainer.folioReader.isNight(self.readerConfig.nightModeMenuBackground, UIColor.white)
        let tintColor = readerConfig.tintColor
        let navText = self.readerContainer.folioReader.isNight(UIColor.white, UIColor.black)
        let font = UIFont(name: "Avenir-Light", size: 17)!
        setTranslucentNavigation(color: navBackground, tintColor: tintColor, titleColor: navText, andFont: font)
    }

    func configureNavBarButtons() {

        // Navbar buttons
        let shareIcon = UIImage(readerImageNamed: "icon-navbar-share")?.ignoreSystemTint(withConfiguration: self.readerConfig)
        let audioIcon = UIImage(readerImageNamed: "icon-navbar-tts")?.ignoreSystemTint(withConfiguration: self.readerConfig) //man-speech-icon
        let closeIcon = UIImage(readerImageNamed: "icon-navbar-close")?.ignoreSystemTint(withConfiguration: self.readerConfig)
        let tocIcon = UIImage(readerImageNamed: "icon-navbar-toc")?.ignoreSystemTint(withConfiguration: self.readerConfig)
        let fontIcon = UIImage(readerImageNamed: "icon-navbar-font")?.ignoreSystemTint(withConfiguration: self.readerConfig)
        let space = 70 as CGFloat

        let menu = UIBarButtonItem(image: closeIcon, style: .plain, target: self, action:#selector(closeReader(_:)))
        let toc = UIBarButtonItem(image: tocIcon, style: .plain, target: self, action:#selector(presentChapterList(_:)))

        navigationItem.leftBarButtonItems = [menu, toc]

        var rightBarIcons = [UIBarButtonItem]()

        if (self.readerConfig.allowSharing == true) {
            rightBarIcons.append(UIBarButtonItem(image: shareIcon, style: .plain, target: self, action:#selector(shareChapter(_:))))
        }

        if (self.book.hasAudio() == true || self.readerConfig.enableTTS == true) {
            rightBarIcons.append(UIBarButtonItem(image: audioIcon, style: .plain, target: self, action:#selector(presentPlayerMenu(_:))))
        }

        let font = UIBarButtonItem(image: fontIcon, style: .plain, target: self, action: #selector(presentFontsMenu))
        font.width = space

        rightBarIcons.append(contentsOf: [font])
        navigationItem.rightBarButtonItems = rightBarIcons
    }

    func reloadData() {
        self.loadingView.stopAnimating()
        self.totalPages = (self.book.spine.spineReferences.count ?? 0)

        self.collectionView.reloadData()
        self.configureNavBarButtons()
        self.setCollectionViewProgressiveDirection()

        guard
            let bookId = self.book.name,
            let position = self.readerContainer.folioReader.savedPositionForCurrentBook as? NSDictionary,
            let pageNumber = position["pageNumber"] as? Int,
            (pageNumber > 0) else {
                self.currentPageNumber = 1
                return
        }

        self.changePageWith(page: pageNumber)
        self.currentPageNumber = pageNumber
    }

    // MARK: Change page progressive direction

    private func transformViewForRTL(_ view: UIView?) {
        if (self.readerContainer.folioReader.needsRTLChange == true) {
            view?.transform = CGAffineTransform(scaleX: -1, y: 1)
        } else {
            view?.transform = CGAffineTransform.identity
        }
    }

    func setCollectionViewProgressiveDirection() {
        self.transformViewForRTL(self.collectionView)
    }

    func setPageProgressiveDirection(_ page: FolioReaderPage) {
        self.transformViewForRTL(page)
    }

    // MARK: Change layout orientation

    /// Get internal page offset before layout change
    private func updatePageOffsetRate() {
        guard let currentPage = self.currentPage else {
            return
        }

        let pageScrollView = currentPage.webView.scrollView
        let contentSize = pageScrollView.contentSize.forDirection(withConfiguration: self.readerConfig)
        let contentOffset = pageScrollView.contentOffset.forDirection(withConfiguration: self.readerConfig)
        self.pageOffsetRate = (contentSize != 0 ? (contentOffset / contentSize) : 0)
    }

    func setScrollDirection(_ direction: FolioReaderScrollDirection) {
        guard let currentPage = self.currentPage else {
            return
        }

        let pageScrollView = currentPage.webView.scrollView

        // Get internal page offset before layout change
        self.updatePageOffsetRate()
        // Change layout
        self.readerConfig.scrollDirection = direction
        self.collectionViewLayout.scrollDirection = .direction(withConfiguration: self.readerConfig)
        self.currentPage?.setNeedsLayout()
        self.collectionView.collectionViewLayout.invalidateLayout()
        self.collectionView.setContentOffset(frameForPage(self.currentPageNumber).origin, animated: false)

        // Page progressive direction
        self.setCollectionViewProgressiveDirection()
        delay(0.2) { self.setPageProgressiveDirection(currentPage) }


        /**
         *  This delay is needed because the page will not be ready yet
         *  so the delay wait until layout finished the changes.
         */
        delay(0.1) {
            var pageOffset = (pageScrollView.contentSize.forDirection(withConfiguration: self.readerConfig) * self.pageOffsetRate)

            // Fix the offset for paged scroll
            if (self.readerConfig.scrollDirection == .horizontal && self.pageWidth != 0) {
                let page = round(pageOffset / self.pageWidth)
                pageOffset = (page * self.pageWidth)
            }

            let pageOffsetPoint = self.readerConfig.isDirection(CGPoint(x: 0, y: pageOffset), CGPoint(x: pageOffset, y: 0), CGPoint(x: 0, y: pageOffset))
            pageScrollView.setContentOffset(pageOffsetPoint, animated: true)
        }
    }

    // MARK: Status bar and Navigation bar

    func hideBars() {

        guard (self.readerConfig.shouldHideNavigationOnTap == true) else {
            return
        }

        self.updateBarsStatus(true)
    }

    func showBars() {
        self.configureNavBar()
        self.updateBarsStatus(false)
    }

    func toggleBars() {
        guard (self.readerConfig.shouldHideNavigationOnTap == true) else {
            return
        }

        let shouldHide = !self.navigationController!.isNavigationBarHidden
        if shouldHide == false {
            self.configureNavBar()
        }

        self.updateBarsStatus(shouldHide)
    }

    private func updateBarsStatus(_ shouldHide: Bool, shouldShowIndicator: Bool = false) {

        self.readerContainer.shouldHideStatusBar = shouldHide

        UIView.animate(withDuration: 0.25, animations: {
            self.readerContainer.setNeedsStatusBarAppearanceUpdate()

            // Show minutes indicator
            if (shouldShowIndicator == true) {
                self.pageIndicatorView?.minutesLabel.alpha = (shouldHide == true ? 0 : 1)
            }
        }, completion: { (finished: Bool) in
            self.navigationController?.setNavigationBarHidden(shouldHide, animated: true)
        })
    }

    // MARK: UICollectionViewDataSource

    open func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }

    open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return totalPages
    }

    open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        var reuseableCell = collectionView.dequeueReusableCell(withReuseIdentifier: kReuseCellIdentifier, for: indexPath) as? FolioReaderPage
        guard let pageCell = reuseableCell else {
            return UICollectionViewCell()
        }

        return self.configure(readerPageCell: pageCell, atIndexPath: indexPath)
    }

    private func configure(readerPageCell cell: FolioReaderPage, atIndexPath indexPath: IndexPath) -> FolioReaderPage {

        cell.setup(withReaderContainer: self.readerContainer)
        cell.pageNumber = (indexPath as NSIndexPath).row+1
        cell.webView.scrollView.delegate = self
        cell.webView.setupScrollDirection()
        cell.webView.frame = cell.webViewFrame()
        cell.delegate = self
        cell.backgroundColor = UIColor.clear

        setPageProgressiveDirection(cell)

        // Configure the cell
        guard
            let resource = self.book.spine.spineReferences[(indexPath as NSIndexPath).row].resource,
            var html = try? String(contentsOfFile: resource.fullHref, encoding: String.Encoding.utf8) else {
                return cell
        }

        let mediaOverlayStyleColors = "\"\(self.readerConfig.mediaOverlayColor.hexString(false))\", \"\(self.readerConfig.mediaOverlayColor.highlightColor().hexString(false))\""

        // Inject CSS
        let jsFilePath = Bundle.frameworkBundle().path(forResource: "Bridge", ofType: "js")
        let cssFilePath = Bundle.frameworkBundle().path(forResource: "Style", ofType: "css")
        let cssTag = "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(cssFilePath!)\">"
        let jsTag = "<script type=\"text/javascript\" src=\"\(jsFilePath!)\"></script>" +
        "<script type=\"text/javascript\">setMediaOverlayStyleColors(\(mediaOverlayStyleColors))</script>"

        let toInject = "\n\(cssTag)\n\(jsTag)\n</head>"
        html = html.replacingOccurrences(of: "</head>", with: toInject)

        // Font class name
        var classes = self.readerContainer.folioReader.currentFont.cssIdentifier
        classes += " " + self.readerContainer.folioReader.currentMediaOverlayStyle.className()

        // Night mode
        if (self.readerContainer.folioReader.nightMode == true) {
            classes += " nightMode"
        }

        // Font Size
        classes += " \(self.readerContainer.folioReader.currentFontSize.cssIdentifier)"

        html = html.replacingOccurrences(of: "<html ", with: "<html class=\"\(classes)\"")

        // Let the delegate adjust the html string
        if let modifiedHtmlContent = self.delegate?.htmlContentForPage?(cell, htmlContent: html) {
            html = modifiedHtmlContent
        }

        cell.loadHTMLString(html, baseURL: URL(fileURLWithPath: (resource.fullHref as NSString).deletingLastPathComponent))

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAtIndexPath indexPath: IndexPath) -> CGSize {
        return CGSize(width: collectionView.frame.width, height: collectionView.frame.height)
    }

    // MARK: - Device rotation

    override open func willRotate(to toInterfaceOrientation: UIInterfaceOrientation, duration: TimeInterval) {
        guard self.readerContainer.folioReader.isReaderReady else { return }

        setPageSize(toInterfaceOrientation)
        updateCurrentPage()

        if (self.currentOrientation == nil || (self.currentOrientation?.isPortrait != toInterfaceOrientation.isPortrait)) {

            var pageIndicatorFrame = pageIndicatorView?.frame
            pageIndicatorFrame?.origin.y = ((screenBounds.size.height < screenBounds.size.width) ? (self.collectionView.frame.height - pageIndicatorHeight) : (self.collectionView.frame.width - pageIndicatorHeight))
            pageIndicatorFrame?.origin.x = 0
            pageIndicatorFrame?.size.width = ((screenBounds.size.height < screenBounds.size.width) ? (self.collectionView.frame.width) : (self.collectionView.frame.height))
            pageIndicatorFrame?.size.height = pageIndicatorHeight

            var scrollScrubberFrame = scrollScrubber?.slider.frame;
            scrollScrubberFrame?.origin.x = ((screenBounds.size.height < screenBounds.size.width) ? (view.frame.width - 100) : (view.frame.height + 10))
            scrollScrubberFrame?.size.height = ((screenBounds.size.height < screenBounds.size.width) ? (self.collectionView.frame.height - 100) : (self.collectionView.frame.width - 100))

            self.collectionView.collectionViewLayout.invalidateLayout()

            UIView.animate(withDuration: duration, animations: {

                // Adjust page indicator view
                if let pageIndicatorFrame = pageIndicatorFrame {
                    self.pageIndicatorView?.frame = pageIndicatorFrame
                    self.pageIndicatorView?.reloadView(updateShadow: true)
                }

                // Adjust scroll scrubber slider
                if let scrollScrubberFrame = scrollScrubberFrame {
                    self.scrollScrubber?.slider.frame = scrollScrubberFrame
                }

                // Adjust collectionView
                self.collectionView.contentSize = self.readerConfig.isDirection(
                    CGSize(width: self.pageWidth, height: self.pageHeight * CGFloat(self.totalPages)),
                    CGSize(width: self.pageWidth * CGFloat(self.totalPages), height: self.pageHeight),
                    CGSize(width: self.pageWidth * CGFloat(self.totalPages), height: self.pageHeight)
                )
                self.collectionView.setContentOffset(self.frameForPage(self.currentPageNumber).origin, animated: false)
                self.collectionView.collectionViewLayout.invalidateLayout()

                // Adjust internal page offset
                self.updatePageOffsetRate()
            })
        }

        self.currentOrientation = toInterfaceOrientation
    }

    override open func didRotate(from fromInterfaceOrientation: UIInterfaceOrientation) {
        guard
            (self.readerContainer.folioReader.isReaderReady == true),
            let currentPage = currentPage else {
                return
        }

        // Update pages
        pagesForCurrentPage(currentPage)
        currentPage.refreshPageMode()

        scrollScrubber?.setSliderVal()

        // After rotation fix internal page offset
        var pageOffset = (currentPage.webView.scrollView.contentSize.forDirection(withConfiguration: self.readerConfig) * pageOffsetRate)

        // Fix the offset for paged scroll
        if (self.readerConfig.scrollDirection == .horizontal && self.pageWidth != 0) {
            let page = round(pageOffset / self.pageWidth)
            pageOffset = page * self.pageWidth
        }

        let pageOffsetPoint = self.readerConfig.isDirection(CGPoint(x: 0, y: pageOffset), CGPoint(x: pageOffset, y: 0), CGPoint(x: 0, y: pageOffset))
        currentPage.webView.scrollView.setContentOffset(pageOffsetPoint, animated: true)
    }

    override open func willAnimateRotation(to toInterfaceOrientation: UIInterfaceOrientation, duration: TimeInterval) {
        guard self.readerContainer.folioReader.isReaderReady else {
            return
        }

        self.collectionView.scrollToItem(at: IndexPath(row: self.currentPageNumber - 1, section: 0), at: UICollectionViewScrollPosition(), animated: false)
        if ((self.currentPageNumber + 1) >= totalPages) {
            UIView.animate(withDuration: duration, animations: {
                self.collectionView.setContentOffset(self.frameForPage(self.currentPageNumber).origin, animated: false)
            })
        }
    }

    // MARK: - Page

    func setPageSize(_ orientation: UIInterfaceOrientation) {
        if orientation.isPortrait {
            if (screenBounds.size.width < screenBounds.size.height) {
                self.pageWidth = self.view.frame.width
                self.pageHeight = self.view.frame.height
            } else {
                self.pageWidth = self.view.frame.height
                self.pageHeight = self.view.frame.width
            }
        } else {
            if (screenBounds.size.width > screenBounds.size.height) {
                self.pageWidth = self.view.frame.width
                self.pageHeight = self.view.frame.height
            } else {
                self.pageWidth = self.view.frame.height
                self.pageHeight = self.view.frame.width
            }
        }
    }

    func updateCurrentPage(_ completion: (() -> Void)? = nil) {
        updateCurrentPage(nil) { () -> Void in
            completion?()
        }
    }

    func updateCurrentPage(_ page: FolioReaderPage? = nil, completion: (() -> Void)? = nil) {
        if let page = page {
            currentPage = page
            self.previousPageNumber = page.pageNumber-1
            self.currentPageNumber = page.pageNumber
        } else {
            let currentIndexPath = getCurrentIndexPath()
            currentPage = collectionView.cellForItem(at: currentIndexPath) as? FolioReaderPage

            self.previousPageNumber = (currentIndexPath as NSIndexPath).row
            self.currentPageNumber = (currentIndexPath as NSIndexPath).row+1
        }

        self.nextPageNumber = (((self.currentPageNumber + 1) <= totalPages) ? (self.currentPageNumber + 1) : self.currentPageNumber)

        // Set pages
        guard let currentPage = currentPage else {
            completion?()
            return
        }

        scrollScrubber?.setSliderVal()

        if let readingTime = currentPage.webView.js("getReadingTime()") {
            pageIndicatorView?.totalMinutes = Int(readingTime)!
        } else {
            pageIndicatorView?.totalMinutes = 0
        }
        pagesForCurrentPage(currentPage)

        delegate?.pageDidAppear?(currentPage)

        completion?()
    }

    func pagesForCurrentPage(_ page: FolioReaderPage?) {
        guard let page = page else { return }

        let pageSize = self.readerConfig.isDirection(pageHeight, self.pageWidth, pageHeight)
        let contentSize = page.webView.scrollView.contentSize.forDirection(withConfiguration: self.readerConfig)
        self.pageIndicatorView?.totalPages = ((pageSize != 0) ? Int(ceil(contentSize / pageSize)) : 0)

        let pageOffSet = self.readerConfig.isDirection(page.webView.scrollView.contentOffset.x, page.webView.scrollView.contentOffset.x, page.webView.scrollView.contentOffset.y)
        let webViewPage = pageForOffset(pageOffSet, pageHeight: pageSize)

        self.pageIndicatorView?.currentPage = webViewPage
    }

    func pageForOffset(_ offset: CGFloat, pageHeight height: CGFloat) -> Int {
        guard (height != 0) else {
            return 0
        }

        let page = Int(ceil(offset / height))+1
        return page
    }

    func getCurrentIndexPath() -> IndexPath {
        let indexPaths = collectionView.indexPathsForVisibleItems
        var indexPath = IndexPath()

        if indexPaths.count > 1 {
            let first = indexPaths.first! as IndexPath
            let last = indexPaths.last! as IndexPath

            switch self.pageScrollDirection {
            case .up, .left:
                if (first as NSIndexPath).compare(last) == .orderedAscending {
                    indexPath = last
                } else {
                    indexPath = first
                }
            default:
                if (first as NSIndexPath).compare(last) == .orderedAscending {
                    indexPath = first
                } else {
                    indexPath = last
                }
            }
        } else {
            indexPath = indexPaths.first ?? IndexPath(row: 0, section: 0)
        }

        return indexPath
    }

    func frameForPage(_ page: Int) -> CGRect {
        return self.readerConfig.isDirection(
            CGRect(x: 0, y: self.pageHeight * CGFloat(page-1), width: self.pageWidth, height: self.pageHeight),
            CGRect(x: self.pageWidth * CGFloat(page-1), y: 0, width: self.pageWidth, height: self.pageHeight),
            CGRect(x: 0, y: self.pageHeight * CGFloat(page-1), width: self.pageWidth, height: self.pageHeight)
        )
    }

    func changePageWith(page: Int, andFragment fragment: String, animated: Bool = false, completion: (() -> Void)? = nil) {
        if (self.currentPageNumber == page) {
            if let currentPage = currentPage , fragment != "" {
                currentPage.handleAnchor(fragment, avoidBeginningAnchors: true, animated: animated)
            }
            completion?()
        } else {
            tempFragment = fragment
            changePageWith(page: page, animated: animated, completion: { () -> Void in
                self.updateCurrentPage({ () -> Void in
                    completion?()
                })
            })
        }
    }

    func changePageWith(href: String, animated: Bool = false, completion: (() -> Void)? = nil) {
        let item = findPageByHref(href)
        let indexPath = IndexPath(row: item, section: 0)
        changePageWith(indexPath: indexPath, animated: animated, completion: { () -> Void in
            self.updateCurrentPage({ () -> Void in
                completion?()
            })
        })
    }

    func changePageWith(href: String, andAudioMarkID markID: String) {
        if recentlyScrolled { return } // if user recently scrolled, do not change pages or scroll the webview
        guard let currentPage = currentPage else { return }

        let item = findPageByHref(href)
        let pageUpdateNeeded = item+1 != currentPage.pageNumber
        let indexPath = IndexPath(row: item, section: 0)
        changePageWith(indexPath: indexPath, animated: true) { () -> Void in
            if pageUpdateNeeded {
                self.updateCurrentPage({ () -> Void in
                    currentPage.audioMarkID(markID)
                })
            } else {
                currentPage.audioMarkID(markID)
            }
        }
    }

    func changePageWith(indexPath: IndexPath, animated: Bool = false, completion: (() -> Void)? = nil) {
        guard indexPathIsValid(indexPath) else {
            print("ERROR: Attempt to scroll to invalid index path")
            completion?()
            return
        }

        UIView.animate(withDuration: animated ? 0.3 : 0, delay: 0, options: UIViewAnimationOptions(), animations: { () -> Void in
            self.collectionView.scrollToItem(at: indexPath, at: .direction(withConfiguration: self.readerConfig), animated: false)
        }) { (finished: Bool) -> Void in
            completion?()
        }
    }

    func indexPathIsValid(_ indexPath: IndexPath) -> Bool {
        let section = (indexPath as NSIndexPath).section
        let row = (indexPath as NSIndexPath).row
        let lastSectionIndex = numberOfSections(in: collectionView) - 1

        //Make sure the specified section exists
        if section > lastSectionIndex {
            return false
        }

        let rowCount = self.collectionView(collectionView, numberOfItemsInSection: (indexPath as NSIndexPath).section) - 1
        return row <= rowCount
    }

    func isLastPage() -> Bool{
        return (currentPageNumber == self.nextPageNumber)
    }

    func changePageToNext(_ completion: (() -> Void)? = nil) {
        changePageWith(page: self.nextPageNumber, animated: true) { () -> Void in
            completion?()
        }
    }

    func changePageToPrevious(_ completion: (() -> Void)? = nil) {
        changePageWith(page: self.previousPageNumber, animated: true) { () -> Void in
            completion?()
        }
    }

    /**
     Find a page by FRTocReference.
     */
    func findPageByResource(_ reference: FRTocReference) -> Int {
        var count = 0
        for item in self.book.spine.spineReferences {
            if let resource = reference.resource, item.resource == resource {
                return count
            }
            count += 1
        }
        return count
    }

    /**
     Find a page by href.
     */
    func findPageByHref(_ href: String) -> Int {
        var count = 0
        for item in self.book.spine.spineReferences {
            if item.resource.href == href {
                return count
            }
            count += 1
        }
        return count
    }

    /**
     Find and return the current chapter resource.
     */
    func getCurrentChapter() -> FRResource? {
        for item in self.book.flatTableOfContents {
            if
                let reference = self.book.spine.spineReferences[safe: (self.currentPageNumber - 1)],
                let resource = item.resource,
                (resource == reference.resource) {
                return item.resource
            }
        }
        return nil
    }

    /**
     Find and return the current chapter name.
     */
    func getCurrentChapterName() -> String? {
        for item in self.book.flatTableOfContents {
            guard
                let reference = self.book.spine.spineReferences[safe: (self.currentPageNumber - 1)],
                let resource = item.resource,
                (resource == reference.resource),
                let title = item.title else {
                    continue
            }

            return title
        }

        return nil
    }

    // MARK: Public page methods

    /**
     Changes the current page of the reader.

     - parameter page: The target page index. Note: The page index starts at 1 (and not 0).
     - parameter animated: En-/Disables the animation of the page change.
     - parameter completion: A Closure which is called if the page change is completed.
     */
    open func changePageWith(page: Int, animated: Bool = false, completion: (() -> Void)? = nil) {
        if page > 0 && page-1 < totalPages {
            let indexPath = IndexPath(row: page-1, section: 0)
            changePageWith(indexPath: indexPath, animated: animated, completion: { () -> Void in
                self.updateCurrentPage({ () -> Void in
                    completion?()
                })
            })
        }
    }

    // MARK: - Audio Playing

    func audioMark(href: String, fragmentID: String) {
        changePageWith(href: href, andAudioMarkID: fragmentID)
    }

    // MARK: - Sharing

    /**
     Sharing chapter method.
     */
    func shareChapter(_ sender: UIBarButtonItem) {
        guard let currentPage = currentPage else { return }

        if let chapterText = currentPage.webView.js("getBodyText()") {
            let htmlText = chapterText.replacingOccurrences(of: "[\\n\\r]+", with: "<br />", options: .regularExpression)
            var subject = readerConfig.localizedShareChapterSubject
            var html = ""
            var text = ""
            var bookTitle = ""
            var chapterName = ""
            var authorName = ""
            var shareItems = [AnyObject]()

            // Get book title
            if let title = self.book.title() {
                bookTitle = title
                subject += " “\(title)”"
            }

            // Get chapter name
            if let chapter = getCurrentChapterName() {
                chapterName = chapter
            }

            // Get author name
            if let author = self.book.metadata.creators.first {
                authorName = author.name
            }

            // Sharing html and text
            html = "<html><body>"
            html += "<br /><hr> <p>\(htmlText)</p> <hr><br />"
            html += "<center><p style=\"color:gray\">"+readerConfig.localizedShareAllExcerptsFrom+"</p>"
            html += "<b>\(bookTitle)</b><br />"
            html += readerConfig.localizedShareBy+" <i>\(authorName)</i><br />"

            if let bookShareLink = readerConfig.localizedShareWebLink {
                html += "<a href=\"\(bookShareLink.absoluteString)\">\(bookShareLink.absoluteString)</a>"
                shareItems.append(bookShareLink as AnyObject)
            }

            html += "</center></body></html>"
            text = "\(chapterName)\n\n“\(chapterText)” \n\n\(bookTitle) \n\(readerConfig.localizedShareBy) \(authorName)"

            let act = FolioReaderSharingProvider(subject: subject, text: text, html: html)
            shareItems.insert(contentsOf: [act, "" as AnyObject], at: 0)

            let activityViewController = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
            activityViewController.excludedActivityTypes = [UIActivityType.print, UIActivityType.postToVimeo]

            // Pop style on iPad
            if let actv = activityViewController.popoverPresentationController {
                actv.barButtonItem = sender
            }

            present(activityViewController, animated: true, completion: nil)
        }
    }

    /**
     Sharing highlight method.
     */
    func shareHighlight(_ string: String, rect: CGRect) {
        var subject = readerConfig.localizedShareHighlightSubject
        var html = ""
        var text = ""
        var bookTitle = ""
        var chapterName = ""
        var authorName = ""
        var shareItems = [AnyObject]()

        // Get book title
        if let title = self.book.title() {
            bookTitle = title
            subject += " “\(title)”"
        }

        // Get chapter name
        if let chapter = getCurrentChapterName() {
            chapterName = chapter
        }

        // Get author name
        if let author = self.book.metadata.creators.first {
            authorName = author.name
        }

        // Sharing html and text
        html = "<html><body>"
        html += "<br /><hr> <p>\(chapterName)</p>"
        html += "<p>\(string)</p> <hr><br />"
        html += "<center><p style=\"color:gray\">"+readerConfig.localizedShareAllExcerptsFrom+"</p>"
        html += "<b>\(bookTitle)</b><br />"
        html += readerConfig.localizedShareBy+" <i>\(authorName)</i><br />"

        if let bookShareLink = readerConfig.localizedShareWebLink {
            html += "<a href=\"\(bookShareLink.absoluteString)\">\(bookShareLink.absoluteString)</a>"
            shareItems.append(bookShareLink as AnyObject)
        }

        html += "</center></body></html>"
        text = "\(chapterName)\n\n“\(string)” \n\n\(bookTitle) \n\(readerConfig.localizedShareBy) \(authorName)"

        let act = FolioReaderSharingProvider(subject: subject, text: text, html: html)
        shareItems.insert(contentsOf: [act, "" as AnyObject], at: 0)

        let activityViewController = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
        activityViewController.excludedActivityTypes = [UIActivityType.print, UIActivityType.postToVimeo]

        // Pop style on iPad
        if let actv = activityViewController.popoverPresentationController {
            actv.sourceView = currentPage
            actv.sourceRect = rect
        }

        present(activityViewController, animated: true, completion: nil)
    }

    // MARK: - ScrollView Delegate

    open func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.isScrolling = true
        clearRecentlyScrolled()
        recentlyScrolled = true
        pointNow = scrollView.contentOffset

        if let currentPage = currentPage {
            currentPage.webView.createMenu(options: true)
            currentPage.webView.setMenuVisible(false)
        }

        scrollScrubber?.scrollViewWillBeginDragging(scrollView)
    }

    open func scrollViewDidScroll(_ scrollView: UIScrollView) {

        if (navigationController?.isNavigationBarHidden == false) {
            self.toggleBars()
        }

        scrollScrubber?.scrollViewDidScroll(scrollView)

        let isCollectionScrollView = (scrollView is UICollectionView)
        let scrollType: ScrollType = ((isCollectionScrollView == true) ? .chapter : .page)

        // Update current reading page
        if (isCollectionScrollView == false), let page = currentPage {

            let pageSize = self.readerConfig.isDirection(self.pageHeight, self.pageWidth, self.pageHeight)
            let contentOffset = page.webView.scrollView.contentOffset.forDirection(withConfiguration: self.readerConfig)
            let contentSize = page.webView.scrollView.contentSize.forDirection(withConfiguration: self.readerConfig)
            if (contentOffset + pageSize <= contentSize) {

                let webViewPage = pageForOffset(contentOffset, pageHeight: pageSize)

                if (readerConfig.scrollDirection == .horizontalWithVerticalContent) {
                    let currentIndexPathRow = (page.pageNumber - 1)

                    // if the cell reload doesn't save the top position offset
                    if let oldOffSet = self.currentWebViewScrollPositions[currentIndexPathRow], (abs(oldOffSet.y - scrollView.contentOffset.y) > 100) {
                        // Do nothing
                    } else {
                        self.currentWebViewScrollPositions[currentIndexPathRow] = scrollView.contentOffset
                    }
                }

                if (pageIndicatorView?.currentPage != webViewPage) {
                    pageIndicatorView?.currentPage = webViewPage
                }
            }
        }

        self.updatePageScrollDirection(inScrollView: scrollView, forScrollType: scrollType)
    }

    private func updatePageScrollDirection(inScrollView scrollView: UIScrollView, forScrollType scrollType: ScrollType) {

        let scrollViewContentOffsetForDirection = scrollView.contentOffset.forDirection(withConfiguration: self.readerConfig, scrollType: scrollType)
        let pointNowForDirection = pointNow.forDirection(withConfiguration: self.readerConfig, scrollType: scrollType)
        // The movement is either positive or negative. This happens if the page change isn't completed. Toggle to the other scroll direction then.
        let isCurrentlyPositive = (self.pageScrollDirection == .left || self.pageScrollDirection == .up)

        if (scrollViewContentOffsetForDirection < pointNowForDirection) {
            self.pageScrollDirection = .negative(withConfiguration: self.readerConfig, scrollType: scrollType)
        } else if (scrollViewContentOffsetForDirection > pointNowForDirection) {
            self.pageScrollDirection = .positive(withConfiguration: self.readerConfig, scrollType: scrollType)
        } else if (isCurrentlyPositive == true) {
            self.pageScrollDirection = .negative(withConfiguration: self.readerConfig, scrollType: scrollType)
        } else {
            self.pageScrollDirection = .positive(withConfiguration: self.readerConfig, scrollType: scrollType)
        }
    }

    open func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.isScrolling = false

        // Perform the page after a short delay as the collection view hasn't completed it's transition if this method is called (the index paths aren't right during fast scrolls).
        delay(0.2, closure: { [weak self] in

            if (self?.readerConfig.scrollDirection == .horizontalWithVerticalContent),
                let cell = ((scrollView.superview as? UIWebView)?.delegate as? FolioReaderPage) {
                let currentIndexPathRow = cell.pageNumber - 1
                self?.currentWebViewScrollPositions[currentIndexPathRow] = scrollView.contentOffset
            }

            if (scrollView is UICollectionView) {
                if self?.totalPages > 0 {
                    self?.updateCurrentPage()
                }
            } else {
                self?.scrollScrubber?.scrollViewDidEndDecelerating(scrollView)
            }
        })
    }

    open func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        recentlyScrolledTimer = Timer(timeInterval:recentlyScrolledDelay, target: self, selector: #selector(FolioReaderCenter.clearRecentlyScrolled), userInfo: nil, repeats: false)
        RunLoop.current.add(recentlyScrolledTimer, forMode: RunLoopMode.commonModes)
    }

    func clearRecentlyScrolled() {
        if(recentlyScrolledTimer != nil) {
            recentlyScrolledTimer.invalidate()
            recentlyScrolledTimer = nil
        }
        recentlyScrolled = false
    }

    open func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollScrubber?.scrollViewDidEndScrollingAnimation(scrollView)
    }


    // MARK: NavigationBar Actions

    func closeReader(_ sender: UIBarButtonItem) {
        dismiss()
        self.readerContainer.folioReader.close()
    }

    /**
     Present chapter list
     */
    func presentChapterList(_ sender: UIBarButtonItem) {
        self.readerContainer.folioReader.saveReaderState()

        let chapter = FolioReaderChapterList(folioReader: self.readerContainer.folioReader, readerConfig: self.readerConfig, book: self.readerContainer.book, delegate: self)
        let highlight = FolioReaderHighlightList(folioReader: self.readerContainer.folioReader, readerConfig: self.readerConfig)
        let pageController = PageViewController(folioReader: self.readerContainer.folioReader, readerConfig: self.readerConfig)

        pageController.viewControllerOne = chapter
        pageController.viewControllerTwo = highlight
        pageController.segmentedControlItems = [readerConfig.localizedContentsTitle, readerConfig.localizedHighlightsTitle]

        let nav = UINavigationController(rootViewController: pageController)
        present(nav, animated: true, completion: nil)
    }

    /**
     Present fonts and settings menu
     */
    func presentFontsMenu() {
        self.readerContainer.folioReader.saveReaderState()
        hideBars()

        let menu = FolioReaderFontsMenu(folioReader: self.readerContainer.folioReader, readerConfig: self.readerConfig)
        menu.modalPresentationStyle = .custom

        animator = ZFModalTransitionAnimator(modalViewController: menu)
        animator.isDragable = false
        animator.bounces = false
        animator.behindViewAlpha = 0.4
        animator.behindViewScale = 1
        animator.transitionDuration = 0.6
        animator.direction = ZFModalTransitonDirection.bottom

        menu.transitioningDelegate = animator
        self.present(menu, animated: true, completion: nil)
    }

    /**
     Present audio player menu
     */
    func presentPlayerMenu(_ sender: UIBarButtonItem) {
        self.readerContainer.folioReader.saveReaderState()
        hideBars()

        let menu = FolioReaderPlayerMenu(folioReader: self.readerContainer.folioReader, readerConfig: self.readerConfig)
        menu.modalPresentationStyle = .custom

        animator = ZFModalTransitionAnimator(modalViewController: menu)
        animator.isDragable = true
        animator.bounces = false
        animator.behindViewAlpha = 0.4
        animator.behindViewScale = 1
        animator.transitionDuration = 0.6
        animator.direction = ZFModalTransitonDirection.bottom

        menu.transitioningDelegate = animator
        present(menu, animated: true, completion: nil)
    }

    /**
     Present Quote Share
     */
    func presentQuoteShare(_ string: String) {
        let quoteShare = FolioReaderQuoteShare(initWithText: string, readerConfig: self.readerConfig, folioReader: self.readerContainer.folioReader, book: self.readerContainer.book)
        let nav = UINavigationController(rootViewController: quoteShare)

        if (UIDevice.current.userInterfaceIdiom == .pad) {
            nav.modalPresentationStyle = .formSheet
        }

        present(nav, animated: true, completion: nil)
    }
}

// MARK: FolioPageDelegate

extension FolioReaderCenter: FolioReaderPageDelegate {

    public func pageDidLoad(_ page: FolioReaderPage) {

        if
            let bookId = self.book.name,
            let position = self.readerContainer.folioReader.savedPositionForCurrentBook as? NSDictionary {
            let pageNumber = position["pageNumber"] as? Int
            let offset = self.readerConfig.isDirection(position["pageOffsetY"], position["pageOffsetX"], position["pageOffsetY"]) as? CGFloat
            let pageOffset = offset

            if isFirstLoad {
                updateCurrentPage(page)
                isFirstLoad = false

                if (self.currentPageNumber == pageNumber && pageOffset > 0) {
                    page.scrollPageToOffset(pageOffset!, animated: false)
                }
            } else if (self.isScrolling == false && self.readerContainer.folioReader.needsRTLChange == true) {
                page.scrollPageToBottom()
            }
        } else if isFirstLoad {
            updateCurrentPage(page)
            isFirstLoad = false
        }

        // Go to fragment if needed
        if let fragmentID = tempFragment, let currentPage = currentPage , fragmentID != "" {
            currentPage.handleAnchor(fragmentID, avoidBeginningAnchors: true, animated: true)
            tempFragment = nil
        }
        
        if (readerConfig.scrollDirection == .horizontalWithVerticalContent),
            let offsetPoint = self.currentWebViewScrollPositions[page.pageNumber - 1] {
            page.webView.scrollView.setContentOffset(offsetPoint, animated: false)
        }
        
        // Pass the event to the centers `pageDelegate`
        pageDelegate?.pageDidLoad?(page)
    }
    
    public func pageWillLoad(_ page: FolioReaderPage) {
        // Pass the event to the centers `pageDelegate`
        pageDelegate?.pageWillLoad?(page)
    }
}

// MARK: FolioReaderChapterListDelegate

extension FolioReaderCenter: FolioReaderChapterListDelegate {
    
    func chapterList(_ chapterList: FolioReaderChapterList, didSelectRowAtIndexPath indexPath: IndexPath, withTocReference reference: FRTocReference) {
        let item = findPageByResource(reference)
        
        if item < totalPages {
            let indexPath = IndexPath(row: item, section: 0)
            changePageWith(indexPath: indexPath, animated: false, completion: { () -> Void in
                self.updateCurrentPage()
            })
            tempReference = reference
        } else {
            print("Failed to load book because the requested resource is missing.")
        }
    }
    
    func chapterList(didDismissedChapterList chapterList: FolioReaderChapterList) {
        updateCurrentPage()
        
        // Move to #fragment
        if let reference = tempReference {
            if let fragmentID = reference.fragmentID, let currentPage = currentPage , fragmentID != "" {
                currentPage.handleAnchor(reference.fragmentID!, avoidBeginningAnchors: true, animated: true)
            }
            tempReference = nil
        }
    }
}
