#import "UCClassBrowserViewController.h"
#import "UCDisasmViewController.h"
#import "AVX512Color.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Lightweight row models

@interface UCClassBrowserEntry : NSObject
@property (nonatomic, assign) Class cls;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSUInteger methodCount;
@end

@implementation UCClassBrowserEntry
@end

@interface UCMethodBrowserEntry : NSObject
@property (nonatomic, assign) Class cls;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, assign) BOOL isClassMethod;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) uint64_t impAddress;
@end

@implementation UCMethodBrowserEntry
@end

#pragma mark - Method list (drill-down from a selected class)

@interface UCMethodListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<UCMethodBrowserEntry *> *allMethods;
@property (nonatomic, strong) NSArray<UCMethodBrowserEntry *> *filteredMethods;

- (instancetype)initWithClassEntry:(UCClassBrowserEntry *)entry;

@end

@implementation UCMethodListViewController

- (instancetype)initWithClassEntry:(UCClassBrowserEntry *)entry {
    self = [super init];
    if (self) {
        self.title = entry.name;
        NSMutableArray<UCMethodBrowserEntry *> *methods = [NSMutableArray array];

        unsigned int instCount = 0;
        Method *instMethods = class_copyMethodList(entry.cls, &instCount);
        if (instMethods) {
            for (unsigned int i = 0; i < instCount; i++) {
                SEL sel = method_getName(instMethods[i]);
                UCMethodBrowserEntry *m = [UCMethodBrowserEntry new];
                m.cls = entry.cls;
                m.selector = sel;
                m.isClassMethod = NO;
                m.impAddress = (uint64_t)(uintptr_t)method_getImplementation(instMethods[i]);
                m.displayName = [NSString stringWithFormat:@"-%s", sel_getName(sel)];
                [methods addObject:m];
            }
            free(instMethods);
        }

        Class metaCls = object_getClass(entry.cls);
        if (metaCls && class_isMetaClass(metaCls)) {
            unsigned int classCount = 0;
            Method *classMethods = class_copyMethodList(metaCls, &classCount);
            if (classMethods) {
                for (unsigned int i = 0; i < classCount; i++) {
                    SEL sel = method_getName(classMethods[i]);
                    UCMethodBrowserEntry *m = [UCMethodBrowserEntry new];
                    m.cls = entry.cls;
                    m.selector = sel;
                    m.isClassMethod = YES;
                    m.impAddress = (uint64_t)(uintptr_t)method_getImplementation(classMethods[i]);
                    m.displayName = [NSString stringWithFormat:@"+%s", sel_getName(sel)];
                    [methods addObject:m];
                }
                free(classMethods);
            }
        }

        [methods sortUsingComparator:^NSComparisonResult(UCMethodBrowserEntry *a, UCMethodBrowserEntry *b) {
            return [a.displayName compare:b.displayName];
        }];

        _allMethods = methods;
        _filteredMethods = methods;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AVX512Color.primaryBackgroundColor;

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search methods...";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"MethodCell"];

    [self.view addSubview:self.tableView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tableView.frame = self.view.bounds;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredMethods.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MethodCell" forIndexPath:indexPath];
    UCMethodBrowserEntry *m = self.filteredMethods[indexPath.row];

    cell.textLabel.text = m.displayName;
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:12];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"0x%llx", m.impAddress];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UCMethodBrowserEntry *m = self.filteredMethods[indexPath.row];

    UCDisasmViewController *disasmVC = [[UCDisasmViewController alloc] initWithClass:m.cls
                                                                             selector:m.selector
                                                                       isClassMethod:m.isClassMethod];
    [self.navigationController pushViewController:disasmVC animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredMethods = self.allMethods;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"displayName CONTAINS[cd] %@", searchText];
        self.filteredMethods = [self.allMethods filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

@end

#pragma mark - UCClassBrowserViewController

@interface UCClassBrowserViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<UCClassBrowserEntry *> *allClasses;
@property (nonatomic, strong) NSArray<UCClassBrowserEntry *> *filteredClasses;

@end

@implementation UCClassBrowserViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadClassSnapshot];
    }
    return self;
}

- (void)loadClassSnapshot {
    NSMutableArray<UCClassBrowserEntry *> *entries = [NSMutableArray array];

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes) {
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            const char *name = class_getName(cls);
            if (!name) continue;

            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            if (methods) free(methods);

            UCClassBrowserEntry *entry = [UCClassBrowserEntry new];
            entry.cls = cls;
            entry.name = [NSString stringWithUTF8String:name];
            entry.methodCount = methodCount;
            [entries addObject:entry];
        }
        free(classes);
    }

    [entries sortUsingComparator:^NSComparisonResult(UCClassBrowserEntry *a, UCClassBrowserEntry *b) {
        return [a.name compare:b.name];
    }];

    self.allClasses = entries;
    self.filteredClasses = entries;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AVX512Color.primaryBackgroundColor;
    self.title = [NSString stringWithFormat:@"Classes (%lu)", (unsigned long)self.allClasses.count];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneAction)];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search classes...";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ClassCell"];

    [self.view addSubview:self.tableView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tableView.frame = self.view.bounds;
}

- (void)doneAction {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredClasses.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ClassCell" forIndexPath:indexPath];
    UCClassBrowserEntry *entry = self.filteredClasses[indexPath.row];

    cell.textLabel.text = entry.name;
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:12];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu methods", (unsigned long)entry.methodCount];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UCClassBrowserEntry *entry = self.filteredClasses[indexPath.row];

    UCMethodListViewController *methodListVC = [[UCMethodListViewController alloc] initWithClassEntry:entry];
    [self.navigationController pushViewController:methodListVC animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredClasses = self.allClasses;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", searchText];
        self.filteredClasses = [self.allClasses filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

@end

NS_ASSUME_NONNULL_END
