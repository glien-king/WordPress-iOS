import Foundation
import CocoaLumberjack
import WordPressShared.WPAnalytics
import WordPressShared.WPStyleGuide
import WordPressShared.WPNoResultsView

/**
 *  @brief      Support for filtering themes by purchasability
 *  @details    Currently purchasing themes via native apps is unsupported
 */
public enum ThemeType {
    case all
    case free
    case premium

    static let mayPurchase = false

    static let types = [all, free, premium]

    var title: String {
        switch self {
        case .all:
            return NSLocalizedString("All", comment: "Browse all themes selection title")
        case .free:
            return NSLocalizedString("Free", comment: "Browse free themes selection title")
        case .premium:
            return NSLocalizedString("Premium", comment: "Browse premium themes selection title")
        }
    }

    var predicate: NSPredicate? {
        switch self {
        case .all:
            return nil
        case .free:
            return NSPredicate(format: "premium == 0")
        case .premium:
            return NSPredicate(format: "premium == 1")
        }
    }
}

/**
 *  @brief      Publicly exposed theme interaction support
 *  @details    Held as weak reference by owned subviews
 */
public protocol ThemePresenter: class {
    var filterType: ThemeType { get set }

    var screenshotWidth: Int { get }

    func currentTheme() -> Theme?
    func activateTheme(_ theme: Theme?)

    func presentCustomizeForTheme(_ theme: Theme?)
    func presentPreviewForTheme(_ theme: Theme?)
    func presentDetailsForTheme(_ theme: Theme?)
    func presentSupportForTheme(_ theme: Theme?)
    func presentViewForTheme(_ theme: Theme?)
}

/// Invalidates the layout whenever the collection view's bounds change
@objc open class ThemeBrowserCollectionViewLayout: UICollectionViewFlowLayout {
    open override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        return shouldInvalidateForNewBounds(newBounds)
    }

    open override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewFlowLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds) as! UICollectionViewFlowLayoutInvalidationContext
        context.invalidateFlowLayoutDelegateMetrics = shouldInvalidateForNewBounds(newBounds)

        return context
    }

    fileprivate func shouldInvalidateForNewBounds(_ newBounds: CGRect) -> Bool {
        guard let collectionView = collectionView else { return false }

        return (newBounds.width != collectionView.bounds.width || newBounds.height != collectionView.bounds.height)
    }
}

@objc open class ThemeBrowserViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, NSFetchedResultsControllerDelegate, UISearchControllerDelegate, UISearchResultsUpdating, ThemePresenter, WPContentSyncHelperDelegate {

    // MARK: - Constants

    static let reuseIdentifierForThemesHeader = "ThemeBrowserSectionHeaderViewThemes"
    static let reuseIdentifierForCustomThemesHeader = "ThemeBrowserSectionHeaderViewCustomThemes"

    // MARK: - Properties: must be set by parent

    /**
     *  @brief      The blog this VC will work with.
     *  @details    Must be set by the creator of this VC.
     */
    open var blog: Blog!

    // MARK: - Properties

    @IBOutlet weak var collectionView: UICollectionView!

    fileprivate lazy var customizerNavigationDelegate: ThemeWebNavigationDelegate = {
        return ThemeWebNavigationDelegate()
    }()

    /**
     *  @brief      The FRCs this VC will use to display filtered content.
     */
    fileprivate lazy var themesController: NSFetchedResultsController<NSFetchRequestResult> = {
        return self.createThemesFetchedResultsController()
    }()

    fileprivate lazy var customThemesController: NSFetchedResultsController<NSFetchRequestResult> = {
        return self.createThemesFetchedResultsController()
    }()

    fileprivate func createThemesFetchedResultsController() -> NSFetchedResultsController<NSFetchRequestResult> {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Theme.entityName())
        fetchRequest.fetchBatchSize = 20
        let sort = NSSortDescriptor(key: "order", ascending: true)
        fetchRequest.sortDescriptors = [sort]
        let frc = NSFetchedResultsController(fetchRequest: fetchRequest,
            managedObjectContext: self.themeService.managedObjectContext,
            sectionNameKeyPath: nil,
            cacheName: nil)
        frc.delegate = self

        return frc
    }

    fileprivate var themeCount: NSInteger {
        return themesController.fetchedObjects?.count ?? 0
    }

    fileprivate var customThemeCount: NSInteger {
        return blog.supports(BlogFeature.customThemes) ? (customThemesController.fetchedObjects?.count ?? 0) : 0
    }

    // Absolute count of available themes for the site, as it comes from the ThemeService

    fileprivate var totalThemeCount: NSInteger = 0 {
        didSet {
            themesHeader?.themeCount = totalThemeCount
        }
    }

    fileprivate var totalCustomThemeCount: NSInteger = 0 {
        didSet {
            customThemesHeader?.themeCount = totalCustomThemeCount
        }
    }

    fileprivate var themesHeader: ThemeBrowserSectionHeaderView? {
        didSet {
            themesHeader?.descriptionLabel.text = NSLocalizedString("WordPress.com Themes",
                                                                    comment: "Title for the WordPress.com themes section, should be the same as in Calypso").localizedUppercase
            themesHeader?.themeCount = totalThemeCount > 0 ? totalThemeCount : themeCount
        }
    }

    fileprivate var customThemesHeader: ThemeBrowserSectionHeaderView? {
        didSet {
            customThemesHeader?.descriptionLabel.text = NSLocalizedString("Uploaded themes",
                                                                          comment: "Title for the user uploaded themes section, should be the same as in Calypso").localizedUppercase
            customThemesHeader?.themeCount = totalCustomThemeCount > 0 ? totalCustomThemeCount : customThemeCount
        }
    }

    fileprivate var hideSectionHeaders: Bool = false

    fileprivate var searchController: UISearchController!

    fileprivate var searchName = "" {
        didSet {
            if searchName != oldValue {
                fetchThemes()
                reloadThemes()
            }
       }
    }

    fileprivate var suspendedSearch = ""

    func resumingSearch() -> Bool {
        return !suspendedSearch.trim().isEmpty
    }

    open var filterType: ThemeType = ThemeType.mayPurchase ? .all : .free

    /**
     *  @brief      Collection view support
     */

    fileprivate enum Section {
        case search
        case info
        case customThemes
        case themes
    }
    fileprivate var sections: [Section]!

    fileprivate func reloadThemes() {
        collectionView?.reloadData()
        updateResults()
    }

    fileprivate func themeAtIndexPath(_ indexPath: IndexPath) -> Theme? {
        if sections[indexPath.section] == .themes {
            return themesController.object(at: IndexPath(row: indexPath.row, section: 0)) as? Theme
        } else if sections[indexPath.section] == .customThemes {
            return customThemesController.object(at: IndexPath(row: indexPath.row, section: 0)) as? Theme
        }
        return nil
    }

    fileprivate lazy var noResultsView: WPNoResultsView = {
        let noResultsView = WPNoResultsView()
        let drakeImage = UIImage(named: "theme-empty-results")
        noResultsView.accessoryView = UIImageView(image: drakeImage)

        return noResultsView
    }()

    fileprivate var noResultsShown: Bool {
        return noResultsView.superview != nil
    }
    fileprivate var presentingTheme: Theme?

    /**
     *  @brief      Load theme screenshots at maximum displayed width
     */
    open var screenshotWidth: Int = {
        let windowSize = UIApplication.shared.keyWindow!.bounds.size
        let vWidth = Styles.imageWidthForFrameWidth(windowSize.width)
        let hWidth = Styles.imageWidthForFrameWidth(windowSize.height)
        let maxWidth = Int(max(hWidth, vWidth))
        return maxWidth
    }()

    /**
     *  @brief      The themes service we'll use in this VC and its helpers
     */
    fileprivate let themeService = ThemeService(managedObjectContext: ContextManager.sharedInstance().mainContext)
    fileprivate var themesSyncHelper: WPContentSyncHelper!
    fileprivate var themesSyncingPage = 0
    fileprivate var customThemesSyncHelper: WPContentSyncHelper!
    fileprivate let syncPadding = 5

    // MARK: - Private Aliases

    fileprivate typealias Styles = WPStyleGuide.Themes

     /**
     *  @brief      Convenience method for browser instantiation
     *
     *  @param      blog     The blog to browse themes for
     *
     *  @returns    ThemeBrowserViewController instance
     */
    open class func browserWithBlog(_ blog: Blog) -> ThemeBrowserViewController {
        let storyboard = UIStoryboard(name: "ThemeBrowser", bundle: nil)
        let viewController = storyboard.instantiateInitialViewController() as! ThemeBrowserViewController
        viewController.blog = blog

        return viewController
    }

    // MARK: - UIViewController

    open override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("Themes", comment: "Title of Themes browser page")

        WPStyleGuide.configureColors(for: view, collectionView: collectionView)

        fetchThemes()
        sections = (themeCount == 0 && customThemeCount == 0) ? [.search, .customThemes, .themes] :
                                                                [.search, .info, .customThemes, .themes]

        configureSearchController()

        updateActiveTheme()
        setupThemesSyncHelper()
        if blog.supports(BlogFeature.customThemes) {
            setupCustomThemesSyncHelper()
        }
        syncContent()
    }

    fileprivate func configureSearchController() {
        extendedLayoutIncludesOpaqueBars = true
        definesPresentationContext = true

        searchController = UISearchController(searchResultsController: nil)
        searchController.dimsBackgroundDuringPresentation = false

        searchController.delegate = self
        searchController.searchResultsUpdater = self

        collectionView.register(ThemeBrowserSearchHeaderView.self,
                                     forSupplementaryViewOfKind: UICollectionElementKindSectionHeader,
                                     withReuseIdentifier: ThemeBrowserSearchHeaderView.reuseIdentifier)

        collectionView.register(UINib(nibName: "ThemeBrowserSectionHeaderView", bundle: Bundle(for: ThemeBrowserSectionHeaderView.self)),
                                    forSupplementaryViewOfKind: UICollectionElementKindSectionHeader,
                                    withReuseIdentifier: ThemeBrowserViewController.reuseIdentifierForThemesHeader)

        collectionView.register(UINib(nibName: "ThemeBrowserSectionHeaderView", bundle: Bundle(for: ThemeBrowserSectionHeaderView.self)),
                                forSupplementaryViewOfKind: UICollectionElementKindSectionHeader,
                                withReuseIdentifier: ThemeBrowserViewController.reuseIdentifierForCustomThemesHeader)

        WPStyleGuide.configureSearchBar(searchController.searchBar)
    }

    fileprivate var searchBarHeight: CGFloat {
        return searchController.searchBar.bounds.height + topLayoutGuide.length
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        collectionView?.collectionViewLayout.invalidateLayout()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        registerForKeyboardNotifications()

        if resumingSearch() {
            beginSearchFor(suspendedSearch)
            suspendedSearch = ""
        }

        guard let theme = presentingTheme else {
            return
        }
        presentingTheme = nil
        if !theme.isCurrentTheme() {
            // presented page may have activated this theme
            updateActiveTheme()
        }
    }

    open override func viewWillDisappear(_ animated: Bool) {

        if searchController.isActive {
            searchController.isActive = false
        }

        super.viewWillDisappear(animated)

        unregisterForKeyboardNotifications()
    }

    open override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    fileprivate func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(ThemeBrowserViewController.keyboardDidShow(_:)), name: NSNotification.Name.UIKeyboardDidShow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ThemeBrowserViewController.keyboardWillHide(_:)), name: NSNotification.Name.UIKeyboardWillHide, object: nil)
    }

    fileprivate func unregisterForKeyboardNotifications() {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIKeyboardDidShow, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIKeyboardWillHide, object: nil)
    }

    open func keyboardDidShow(_ notification: Foundation.Notification) {
        let keyboardFrame = localKeyboardFrameFromNotification(notification)
        let keyboardHeight = collectionView.frame.maxY - keyboardFrame.origin.y

        collectionView.contentInset.bottom = keyboardHeight
        collectionView.scrollIndicatorInsets.top = searchBarHeight
        collectionView.scrollIndicatorInsets.bottom = keyboardHeight
    }

    open func keyboardWillHide(_ notification: Foundation.Notification) {
        let tabBarHeight = tabBarController?.tabBar.bounds.height ?? 0

        collectionView.contentInset.top = topLayoutGuide.length
        collectionView.contentInset.bottom = tabBarHeight
        collectionView.scrollIndicatorInsets.top = searchBarHeight
        collectionView.scrollIndicatorInsets.bottom = tabBarHeight
    }

    fileprivate func localKeyboardFrameFromNotification(_ notification: Foundation.Notification) -> CGRect {
        guard let keyboardFrame = (notification.userInfo?[UIKeyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
                return .zero
        }

        // Convert the frame from window coordinates
        return view.convert(keyboardFrame, from: nil)
    }

    // MARK: - Syncing the list of themes

    fileprivate func updateActiveTheme() {
        let lastActiveThemeId = blog.currentThemeId

        _ = themeService.getActiveTheme(for: blog,
            success: { [weak self] (theme: Theme?) in
                if lastActiveThemeId != theme?.themeId {
                    self?.collectionView?.collectionViewLayout.invalidateLayout()
                }
            },
            failure: { (error) in
                DDLogError("Error updating active theme: \(String(describing: error?.localizedDescription))")
        })
    }

    fileprivate func setupThemesSyncHelper() {
        themesSyncHelper = WPContentSyncHelper()
        themesSyncHelper.delegate = self
    }

    fileprivate func setupCustomThemesSyncHelper() {
        customThemesSyncHelper = WPContentSyncHelper()
        customThemesSyncHelper.delegate = self
    }

    fileprivate func syncContent() {
        if themesSyncHelper.syncContent() &&
            (!blog.supports(BlogFeature.customThemes) ||
                customThemesSyncHelper.syncContent()) {
            updateResults()
        }
    }

    fileprivate func syncMoreThemesIfNeeded(_ indexPath: IndexPath) {
        let paddedCount = indexPath.row + syncPadding
        if paddedCount >= themeCount && themesSyncHelper.hasMoreContent && themesSyncHelper.syncMoreContent() {
            updateResults()
        }
    }

    fileprivate func syncThemePage(_ page: NSInteger, success: ((_ hasMore: Bool) -> Void)?, failure: ((_ error: NSError) -> Void)?) {
        assert(page > 0)
        themesSyncingPage = page
        _ = themeService.getThemesFor(blog,
            page: themesSyncingPage,
            sync: page == 1,
            success: {[weak self](themes: [Theme]?, hasMore: Bool, themeCount: NSInteger) in
                if let success = success {
                    success(hasMore)
                }
                self?.totalThemeCount = themeCount
            },
            failure: { (error) in
                DDLogError("Error syncing themes: \(String(describing: error?.localizedDescription))")
                if let failure = failure,
                    let error = error {
                    failure(error as NSError)
                }
            })
    }

    fileprivate func syncCustomThemes(success: ((_ hasMore: Bool) -> Void)?, failure: ((_ error: NSError) -> Void)?) {
        _ = themeService.getCustomThemes(for: blog,
            sync: true,
            success: {[weak self](themes: [Theme]?, hasMore: Bool, themeCount: NSInteger) in
                if let success = success {
                    success(hasMore)
                }
                self?.totalCustomThemeCount = themeCount
            },
            failure: { (error) in
                DDLogError("Error syncing themes: \(String(describing: error?.localizedDescription))")
                if let failure = failure,
                    let error = error {
                    failure(error as NSError)
                }
            })
    }

    open func currentTheme() -> Theme? {
        guard let themeId = blog.currentThemeId, !themeId.isEmpty else {
            return nil
        }

        for theme in blog.themes as! Set<Theme> {
            if theme.themeId == themeId {
                return theme
            }
        }

        return nil
    }

    fileprivate func updateResults() {
        if themeCount == 0 && customThemeCount == 0 {
            showNoResults()
        } else {
            hideNoResults()
        }
    }

    fileprivate func showNoResults() {
        guard !noResultsShown else {
            return
        }

        let title: String
        if searchController.isActive {
            title = NSLocalizedString("No Themes Found", comment: "Text displayed when theme name search has no matches")
        } else {
            title = NSLocalizedString("Fetching Themes...", comment: "Text displayed while fetching themes")
        }
        noResultsView.titleText = title
        view.addSubview(noResultsView)
        syncMoreThemesIfNeeded(IndexPath(item: 0, section: 0))
    }

    fileprivate func hideNoResults() {
        guard noResultsShown else {
            return
        }

        noResultsView.removeFromSuperview()

        if searchController.isActive {
            collectionView?.reloadData()
        } else {
            sections = [.search, .info, .customThemes, .themes]
            collectionView?.collectionViewLayout.invalidateLayout()
        }
    }

    // MARK: - WPContentSyncHelperDelegate

    func syncHelper(_ syncHelper: WPContentSyncHelper, syncContentWithUserInteraction userInteraction: Bool, success: ((_ hasMore: Bool) -> Void)?, failure: ((_ error: NSError) -> Void)?) {
        if syncHelper == themesSyncHelper {
            syncThemePage(1, success: success, failure: failure)
        } else if syncHelper == customThemesSyncHelper {
            syncCustomThemes(success: success, failure: failure)
        }
    }

    func syncHelper(_ syncHelper: WPContentSyncHelper, syncMoreWithSuccess success: ((_ hasMore: Bool) -> Void)?, failure: ((_ error: NSError) -> Void)?) {
        if syncHelper == themesSyncHelper {
            let nextPage = themesSyncingPage + 1
            syncThemePage(nextPage, success: success, failure: failure)
        }
    }

    func syncContentEnded(_ syncHelper: WPContentSyncHelper) {
        updateResults()
        let lastVisibleTheme = collectionView?.indexPathsForVisibleItems.last ?? IndexPath(item: 0, section: 0)
        if syncHelper == themesSyncHelper {
            syncMoreThemesIfNeeded(lastVisibleTheme)
        }
    }

    func hasNoMoreContent(_ syncHelper: WPContentSyncHelper) {
        if syncHelper == themesSyncHelper {
            themesSyncingPage = 0
        }
        collectionView?.collectionViewLayout.invalidateLayout()
    }

    // MARK: - UICollectionViewDataSource

    open func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch sections[section] {
        case .search, .info:
            return 0
        case .customThemes:
            return customThemeCount
        case .themes:
            return themeCount
        }
    }

    open func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThemeBrowserCell.reuseIdentifier, for: indexPath) as! ThemeBrowserCell

        cell.presenter = self
        cell.theme = themeAtIndexPath(indexPath)

        if sections[indexPath.section] == .themes {
            syncMoreThemesIfNeeded(indexPath)
        }

        return cell
    }

    open func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        switch kind {
        case UICollectionElementKindSectionHeader:
            if sections[indexPath.section] == .search {
                let searchHeader = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ThemeBrowserSearchHeaderView.reuseIdentifier, for: indexPath) as! ThemeBrowserSearchHeaderView

                searchHeader.searchBar = searchController.searchBar

                return searchHeader
            } else if sections[indexPath.section] == .info {
                let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ThemeBrowserHeaderView.reuseIdentifier, for: indexPath) as! ThemeBrowserHeaderView
                header.presenter = self
                return header
            } else {
                // We don't want the collectionView to reuse the section headers
                // since we need to keep a reference to them to update the counts
                if sections[indexPath.section] == .customThemes {
                    customThemesHeader = (collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ThemeBrowserViewController.reuseIdentifierForCustomThemesHeader, for: indexPath) as! ThemeBrowserSectionHeaderView)
                    return customThemesHeader!
                } else {
                    themesHeader = (collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ThemeBrowserViewController.reuseIdentifierForCustomThemesHeader, for: indexPath) as! ThemeBrowserSectionHeaderView)
                    return themesHeader!
                }
            }
        case UICollectionElementKindSectionFooter:
            let footer = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "ThemeBrowserFooterView", for: indexPath)
            return footer
        default:
            fatalError("Unexpected theme browser element")
        }
    }

    open func numberOfSections(in collectionView: UICollectionView) -> Int {
        return sections.count
    }

    // MARK: - UICollectionViewDelegate

    open func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let theme = themeAtIndexPath(indexPath) {
            if theme.isCurrentTheme() {
                presentCustomizeForTheme(theme)
            } else {
                theme.custom ? presentDetailsForTheme(theme) : presentViewForTheme(theme)
            }
        }
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: NSInteger) -> CGSize {
        switch sections[section] {
        case .themes, .customThemes:
            if !hideSectionHeaders
                && blog.supports(BlogFeature.customThemes) {
                return CGSize(width: 0, height: ThemeBrowserSectionHeaderView.height)
            }
            return .zero
        case .search:
            return CGSize(width: 0, height: searchController.searchBar.bounds.height)
        case .info:
            let horizontallyCompact = traitCollection.horizontalSizeClass == .compact
            let height = Styles.headerHeight(horizontallyCompact, includingSearchBar: ThemeType.mayPurchase)

            return CGSize(width: 0, height: height)
        }
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let parentViewWidth = collectionView.frame.size.width

        return Styles.cellSizeForFrameWidth(parentViewWidth)
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
            guard sections[section] == .themes && themesSyncHelper.isLoadingMore else {
                return CGSize.zero
            }

            return CGSize(width: 0, height: Styles.footerHeight)
    }

    open func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        switch sections[section] {
        case .customThemes:
            if !blog.supports(BlogFeature.customThemes) {
                return .zero
            }
            return Styles.themeMargins
        case .themes:
            return Styles.themeMargins
        case .info, .search:
            return Styles.infoMargins
        }
    }

    // MARK: - Search support

    fileprivate func beginSearchFor(_ pattern: String) {
        searchController.isActive = true
        searchController.searchBar.text = pattern

        searchName = pattern
    }

    // MARK: - UISearchControllerDelegate

    open func willPresentSearchController(_ searchController: UISearchController) {
        hideSectionHeaders = true
        if sections[1] == .info {
            collectionView?.collectionViewLayout.invalidateLayout()
            setInfoSectionHidden(true)
        }
    }

    open func didPresentSearchController(_ searchController: UISearchController) {
        WPAppAnalytics.track(.themesAccessedSearch, with: blog)
    }

    open func willDismissSearchController(_ searchController: UISearchController) {
        hideSectionHeaders = false
        searchName = ""
        searchController.searchBar.text = ""
    }

    open func didDismissSearchController(_ searchController: UISearchController) {
        if sections[1] == .themes || sections[1] == .customThemes {
            setInfoSectionHidden(false)
        }
        collectionView.scrollIndicatorInsets.top = topLayoutGuide.length
    }

    fileprivate func setInfoSectionHidden(_ hidden: Bool) {
        let hide = {
            self.collectionView?.deleteSections(IndexSet(integer: 1))
            self.sections = [.search, .customThemes, .themes]
        }

        let show = {
            self.collectionView?.insertSections(IndexSet(integer: 1))
            self.sections = [.search, .info, .customThemes, .themes]
        }

        collectionView.performBatchUpdates({
            hidden ? hide() : show()
        }, completion: nil)
    }

    // MARK: - UISearchResultsUpdating

    open func updateSearchResults(for searchController: UISearchController) {
        searchName = searchController.searchBar.text ?? ""
    }

    // MARK: - NSFetchedResultsController helpers

    fileprivate func searchNamePredicate() -> NSPredicate? {
        guard !searchName.isEmpty else {
            return nil
        }

        return NSPredicate(format: "name contains[c] %@", searchName)
    }

    fileprivate func browsePredicate() -> NSPredicate? {
        return browsePredicateThemesWithCustomValue(false)
    }

    fileprivate func customThemesBrowsePredicate() -> NSPredicate? {
        return browsePredicateThemesWithCustomValue(true)
    }

    fileprivate func browsePredicateThemesWithCustomValue(_ custom: Bool) -> NSPredicate? {
        let blogPredicate = NSPredicate(format: "blog == %@ AND custom == %d", self.blog, custom ? 1 : 0)

        let subpredicates = [blogPredicate, searchNamePredicate(), filterType.predicate].flatMap { $0 }
        switch subpredicates.count {
        case 1:
            return subpredicates[0]
        default:
            return NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
        }
    }

    fileprivate func fetchThemes() {
        do {
            themesController.fetchRequest.predicate = browsePredicate()
            try themesController.performFetch()
            if self.blog.supports(BlogFeature.customThemes) {
                customThemesController.fetchRequest.predicate = customThemesBrowsePredicate()
                try customThemesController.performFetch()
            }
        } catch {
            DDLogError("Error fetching themes: \(error)")
        }
    }

    // MARK: - NSFetchedResultsControllerDelegate

    open func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        reloadThemes()
    }

    // MARK: - ThemePresenter

    open func activateTheme(_ theme: Theme?) {
        guard let theme = theme, !theme.isCurrentTheme() else {
            return
        }

        _ = themeService.activate(theme,
            for: blog,
            success: { [weak self] (theme: Theme?) in
                WPAppAnalytics.track(.themesChangedTheme, withProperties: ["theme_id": theme?.themeId ?? ""], with: self?.blog)

                self?.collectionView?.reloadData()

                let successTitle = NSLocalizedString("Theme Activated", comment: "Title of alert when theme activation succeeds")
                let successFormat = NSLocalizedString("Thanks for choosing %@ by %@", comment: "Message of alert when theme activation succeeds")
                let successMessage = String(format: successFormat, theme?.name ?? "", theme?.author ?? "")
                let manageTitle = NSLocalizedString("Manage site", comment: "Return to blog screen action when theme activation succeeds")
                let okTitle = NSLocalizedString("OK", comment: "Alert dismissal title")
                let alertController = UIAlertController(title: successTitle,
                    message: successMessage,
                    preferredStyle: .alert)
                alertController.addActionWithTitle(manageTitle,
                    style: .default,
                    handler: { [weak self] (action: UIAlertAction) in
                        _ = self?.navigationController?.popViewController(animated: true)
                    })
                alertController.addDefaultActionWithTitle(okTitle, handler: nil)
                alertController.presentFromRootViewController()
            },
            failure: { (error) in
                DDLogError("Error activating theme \(theme.themeId): \(String(describing: error?.localizedDescription))")

                let errorTitle = NSLocalizedString("Activation Error", comment: "Title of alert when theme activation fails")
                let okTitle = NSLocalizedString("OK", comment: "Alert dismissal title")
                let alertController = UIAlertController(title: errorTitle,
                    message: error?.localizedDescription,
                    preferredStyle: .alert)
                alertController.addDefaultActionWithTitle(okTitle, handler: nil)
                alertController.presentFromRootViewController()
        })
    }

    open func installThemeAndPresentCustomizer(_ theme: Theme) {
        _ = themeService.installTheme(theme,
            for: blog,
            success: { [weak self] in
                self?.presentUrlForTheme(theme, url: theme.customizeUrl(), activeButton: false)
            }, failure: nil)
    }

    open func presentCustomizeForTheme(_ theme: Theme?) {
        WPAppAnalytics.track(.themesCustomizeAccessed, with: self.blog)
        presentUrlForTheme(theme, url: theme?.customizeUrl(), activeButton: false)
    }

    open func presentPreviewForTheme(_ theme: Theme?) {
        WPAppAnalytics.track(.themesPreviewedSite, with: self.blog)
        // In order to Try & Customize a theme we first need to install it (Jetpack sites)
        if let theme = theme, self.blog.supports(.customThemes) && !theme.custom {
            installThemeAndPresentCustomizer(theme)
        } else {
            presentUrlForTheme(theme, url: theme?.customizeUrl(), activeButton: false)
        }
    }

    open func presentDetailsForTheme(_ theme: Theme?) {
        WPAppAnalytics.track(.themesDetailsAccessed, with: self.blog)
        presentUrlForTheme(theme, url: theme?.detailsUrl())
    }

    open func presentSupportForTheme(_ theme: Theme?) {
        WPAppAnalytics.track(.themesSupportAccessed, with: self.blog)
        presentUrlForTheme(theme, url: theme?.supportUrl())
    }

    open func presentViewForTheme(_ theme: Theme?) {
        WPAppAnalytics.track(.themesDemoAccessed, with: self.blog)
        presentUrlForTheme(theme, url: theme?.viewUrl())
    }

    open func presentUrlForTheme(_ theme: Theme?, url: String?, activeButton: Bool = true) {
        guard let theme = theme, let url = url.flatMap(URL.init(string:)) else {
            return
        }

        suspendedSearch = searchName
        presentingTheme = theme
        let configuration = WebViewControllerConfiguration(url: url)
        configuration.authenticate(blog: theme.blog)
        configuration.secureInteraction = true
        configuration.customTitle = theme.name
        configuration.navigationDelegate = customizerNavigationDelegate
        let webViewController = WebViewControllerFactory.controller(configuration: configuration)
        var buttons: [UIBarButtonItem]?
        if activeButton && !theme.isCurrentTheme() {
           let activate = UIBarButtonItem(title: ThemeAction.activate.title, style: .plain, target: self, action: #selector(ThemeBrowserViewController.activatePresentingTheme))
            buttons = [activate]
        }
        webViewController.navigationItem.rightBarButtonItems = buttons

        if searchController != nil && searchController.isActive {
            searchController.dismiss(animated: true, completion: {
                self.navigationController?.pushViewController(webViewController, animated: true)
            })
        } else {
            navigationController?.pushViewController(webViewController, animated: true)
        }
    }

    open func activatePresentingTheme() {
        suspendedSearch = ""
        _ = navigationController?.popViewController(animated: true)
        activateTheme(presentingTheme)
        presentingTheme = nil
    }
}
