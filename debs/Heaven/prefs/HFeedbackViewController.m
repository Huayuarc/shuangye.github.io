#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface HFeedbackViewController : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) UITextView *feedbackTextView;
@property (nonatomic, strong) UITextField *contactField;
@property (nonatomic, strong) UIButton *submitButton;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *placeholderLabel;
@end

@implementation HFeedbackViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"意见反馈";

    [self setupUI];
}

- (void)setupUI {
    CGFloat padding = 20;
    CGFloat width = self.view.bounds.size.width - padding * 2;

    // Description label
    UILabel *descLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, 100, width, 20)];
    descLabel.text = @"请描述您的问题或建议：";
    descLabel.font = [UIFont systemFontOfSize:15];
    descLabel.textColor = [UIColor darkGrayColor];
    [self.view addSubview:descLabel];

    // Feedback text view
    self.feedbackTextView = [[UITextView alloc] initWithFrame:CGRectMake(padding, 128, width, 180)];
    self.feedbackTextView.font = [UIFont systemFontOfSize:15];
    self.feedbackTextView.layer.borderWidth = 1;
    self.feedbackTextView.layer.borderColor = [UIColor lightGrayColor].CGColor;
    self.feedbackTextView.layer.cornerRadius = 8;
    self.feedbackTextView.delegate = self;
    self.feedbackTextView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    [self.view addSubview:self.feedbackTextView];

    // Placeholder label
    self.placeholderLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, 138, width - 16, 20)];
    self.placeholderLabel.text = @"请详细描述...";
    self.placeholderLabel.font = [UIFont systemFontOfSize:15];
    self.placeholderLabel.textColor = [UIColor lightGrayColor];
    [self.view addSubview:self.placeholderLabel];

    // Contact field
    UILabel *contactLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, 325, width, 20)];
    contactLabel.text = @"联系方式（可选）:";
    contactLabel.font = [UIFont systemFontOfSize:15];
    contactLabel.textColor = [UIColor darkGrayColor];
    [self.view addSubview:contactLabel];

    self.contactField = [[UITextField alloc] initWithFrame:CGRectMake(padding, 350, width, 40)];
    self.contactField.placeholder = @"QQ / 微信 / 邮箱";
    self.contactField.borderStyle = UITextBorderStyleRoundedRect;
    self.contactField.font = [UIFont systemFontOfSize:15];
    [self.view addSubview:self.contactField];

    // Submit button
    self.submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.submitButton.frame = CGRectMake(padding, 410, width, 44);
    [self.submitButton setTitle:@"提交反馈" forState:UIControlStateNormal];
    self.submitButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.submitButton.backgroundColor = [UIColor systemBlueColor];
    [self.submitButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.submitButton.layer.cornerRadius = 10;
    self.submitButton.layer.masksToBounds = YES;
    [self.submitButton addTarget:self action:@selector(submitFeedback) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.submitButton];

    // Loading indicator
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingIndicator.center = CGPointMake(self.view.bounds.size.width / 2, 470);
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];
}

- (void)textViewDidChange:(UITextView *)textView {
    self.placeholderLabel.hidden = textView.text.length > 0;
}

- (void)submitFeedback {
    NSString *content = [self.feedbackTextView.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *contact = [self.contactField.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (content.length == 0) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"提示"
            message:@"请填写反馈内容"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.submitButton.enabled = NO;
    [self.loadingIndicator startAnimating];

    // Send feedback to server
    NSURL *url = [NSURL URLWithString:@"https://new.abc3.vip/feedback"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.timeoutInterval = 15;

    NSDictionary *body = @{
        @"content": content,
        @"contact": contact ?: @"",
        @"version": @"1.0.1",
    };

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];

    if (jsonError) {
        [self.loadingIndicator stopAnimating];
        self.submitButton.enabled = YES;
        return;
    }

    request.HTTPBody = jsonData;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            self.submitButton.enabled = YES;

            NSString *title, *message;
            if (error) {
                title = @"提交失败";
                message = [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription];
            } else {
                title = @"提交成功";
                message = @"感谢您的反馈！";
                self.feedbackTextView.text = @"";
                self.contactField.text = @"";
                self.placeholderLabel.hidden = NO;
            }

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];

    [task resume];
}

@end
