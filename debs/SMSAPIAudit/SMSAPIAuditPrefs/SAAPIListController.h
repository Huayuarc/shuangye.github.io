#import <UIKit/UIKit.h>
@interface SAAPIListController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,copy) NSString *methodFilter;
@property(nonatomic) BOOL favoritesOnly;
@end
