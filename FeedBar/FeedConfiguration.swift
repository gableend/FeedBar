// swift
import Foundation

internal let defaultSources: [FeedSource] = [
    // MARK: - News
    FeedSource(name: "BBC News", url: "https://feeds.bbci.co.uk/news/rss.xml", domain: "bbc.co.uk", defaultEnabled: true, category: "News"),
    FeedSource(name: "The Guardian World", url: "https://www.theguardian.com/world/rss", domain: "theguardian.com", defaultEnabled: true, category: "News"),
    FeedSource(name: "CNN Top Stories", url: "http://rss.cnn.com/rss/cnn_topstories.rss", domain: "cnn.com", defaultEnabled: true, category: "News"),
    FeedSource(name: "Sky News", url: "https://feeds.skynews.com/feeds/rss/home.xml", domain: "skynews.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "NPR Top Stories", url: "https://feeds.npr.org/1001/rss.xml", domain: "npr.org", defaultEnabled: true, category: "News"),
    FeedSource(name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml", domain: "aljazeera.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "Deutsche Welle", url: "https://rss.dw.com/rdf/rss-en-all", domain: "dw.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "Radio Free Europe", url: "https://www.rferl.org/api/", domain: "rferl.org", defaultEnabled: false, category: "News"),
    FeedSource(name: "The Hill", url: "https://thehill.com/homenews/feed/", domain: "thehill.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "All Africa", url: "https://allafrica.com/tools/headlines/rdf/africa/headlines.rdf", domain: "allafrica.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "VOX World Politics", url: "https://www.vox.com/rss/world-politics/index.xml", domain: "vox.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "ABC News International", url: "https://abcnews.go.com/abcnews/internationalheadlines", domain: "abcnews.go.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "NY Post", url: "https://nypost.com/feed/", domain: "nypost.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "The Conversation", url: "https://theconversation.com/us/articles.atom", domain: "theconversation.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "Hong Kong Free Press", url: "https://hongkongfp.com/feed/", domain: "hongkongfp.com", defaultEnabled: false, category: "News"),
    FeedSource(name: "PBS News Politics", url: "https://www.pbs.org/newshour/feeds/rss/politics", domain: "pbs.org", defaultEnabled: false, category: "News"),

    // MARK: - Business & Finance
    FeedSource(name: "Financial Times", url: "https://www.ft.com/?format=rss", domain: "ft.com", defaultEnabled: true, category: "Business & Finance"),
    FeedSource(name: "WSJ World News", url: "https://feeds.a.dj.com/rss/RSSWorldNews.xml", domain: "wsj.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "WSJ Markets", url: "https://feeds.a.dj.com/rss/RSSMarketsMain.xml", domain: "wsj.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "WSJ Tech", url: "https://feeds.a.dj.com/rss/RSSWSJD.xml", domain: "wsj.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "Bloomberg Technology", url: "https://www.bloomberg.com/feed/podcast/etf-report.xml", domain: "bloomberg.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "Bloomberg Markets", url: "https://feeds.bloomberg.com/markets/news.rss", domain: "bloomberg.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "The Economist", url: "https://www.economist.com/latest/rss.xml", domain: "economist.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "Forbes Business", url: "https://www.forbes.com/business/feed/", domain: "forbes.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "MarketWatch", url: "https://www.marketwatch.com/rss/topstories", domain: "marketwatch.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "Business Insider", url: "https://www.businessinsider.com/rss", domain: "businessinsider.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "McKinsey Insights", url: "https://www.mckinsey.com/rss", domain: "mckinsey.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "Side Hustle Nation", url: "https://www.sidehustlenation.com/feed/", domain: "sidehustlenation.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "Millennial Money", url: "https://millennialmoney.com/category/investing/feed/", domain: "millennialmoney.com", defaultEnabled: false, category: "Business & Finance"),
    FeedSource(name: "FinMasters", url: "https://finmasters.com/feed/", domain: "finmasters.com", defaultEnabled: false, category: "Business & Finance"),

    // MARK: - Tech & Programming
    FeedSource(name: "Hacker News", url: "https://news.ycombinator.com/rss", domain: "ycombinator.com", defaultEnabled: true, category: "Tech & Programming"),
    FeedSource(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", domain: "arstechnica.com", defaultEnabled: true, category: "Tech & Programming"),
    FeedSource(name: "The Verge", url: "https://www.theverge.com/rss/index.xml", domain: "theverge.com", defaultEnabled: false, category: "Tech & Programming"),
    FeedSource(name: "Wired", url: "https://www.wired.com/feed/rss", domain: "wired.com", defaultEnabled: false, category: "Tech & Programming"),
    FeedSource(name: "TechCrunch", url: "https://techcrunch.com/feed/", domain: "techcrunch.com", defaultEnabled: true, category: "Tech & Programming"),
    FeedSource(name: "The Register", url: "https://www.theregister.com/headlines.atom", domain: "theregister.com", defaultEnabled: false, category: "Tech & Programming"),
    FeedSource(name: "MIT Technology Review", url: "https://www.technologyreview.com/topnews.rss", domain: "technologyreview.com", defaultEnabled: true, category: "Tech & Programming"),
    FeedSource(name: "MIT News AI", url: "http://news.mit.edu/rss/topic/artificial-intelligence2", domain: "mit.edu", defaultEnabled: false, category: "Tech & Programming"),
    FeedSource(name: "IEEE Spectrum", url: "https://spectrum.ieee.org/rss/fulltext", domain: "ieee.org", defaultEnabled: false, category: "Tech & Programming"),
    FeedSource(name: "Product Hunt", url: "https://www.producthunt.com/feed", domain: "producthunt.com", defaultEnabled: false, category: "Tech & Programming"),
    FeedSource(name: "VentureBeat", url: "https://venturebeat.com/feed/", domain: "venturebeat.com", defaultEnabled: false, category: "Tech & Programming"),

    // MARK: - VC & Startups
    FeedSource(name: "YC News", url: "https://www.ycombinator.com/blog/rss", domain: "ycombinator.com", defaultEnabled: false, category: "VC & Startups"),
    FeedSource(name: "a16z", url: "https://a16z.com/feed/", domain: "a16z.com", defaultEnabled: false, category: "VC & Startups"),
    FeedSource(name: "Sequoia", url: "https://www.sequoiacap.com/feed/", domain: "sequoiacap.com", defaultEnabled: false, category: "VC & Startups"),

    // MARK: - Web Dev & Design
    FeedSource(name: "CSS-Tricks", url: "https://css-tricks.com/feed/", domain: "css-tricks.com", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "Smashing Magazine", url: "https://www.smashingmagazine.com/feed/", domain: "smashingmagazine.com", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "WPExplorer", url: "https://www.wpexplorer.com/feed/", domain: "wpexplorer.com", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "ThemeIsle", url: "https://themeisle.com/blog/feed/", domain: "themeisle.com", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "WPShout", url: "https://wpshout.com/feed/", domain: "wpshout.com", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "WPTavern", url: "https://wptavern.com/feed", domain: "wptavern.com", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "WPBeginner", url: "https://www.wpbeginner.com/feed/", domain: "wpbeginner.com", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "Torque Magazine", url: "https://torquemag.io/feed/", domain: "torquemag.io", defaultEnabled: false, category: "Web Dev & Design"),
    FeedSource(name: "Node Weekly", url: "https://cprss.s3.amazonaws.com/nodeweekly.com.xml", domain: "nodeweekly.com", defaultEnabled: false, category: "Web Dev & Design"),

    // MARK: - Company Engineering Blogs
    FeedSource(name: "GitHub Blog", url: "https://github.blog/feed/", domain: "github.blog", defaultEnabled: false, category: "Company Engineering Blogs"),
    FeedSource(name: "GitHub Changelog", url: "https://github.blog/changelog/feed/", domain: "github.blog", defaultEnabled: false, category: "Company Engineering Blogs"),
    FeedSource(name: "AWS News Blog", url: "https://aws.amazon.com/blogs/aws/feed/", domain: "aws.amazon.com", defaultEnabled: false, category: "Company Engineering Blogs"),
    FeedSource(name: "Google AI Blog", url: "https://blog.google/technology/ai/rss", domain: "blog.google", defaultEnabled: false, category: "Company Engineering Blogs"),
    FeedSource(name: "Google Security Blog", url: "https://security.googleblog.com/feeds/posts/default", domain: "googleblog.com", defaultEnabled: false, category: "Company Engineering Blogs"),
    FeedSource(name: "Cloudflare Blog", url: "https://blog.cloudflare.com/rss/", domain: "cloudflare.com", defaultEnabled: false, category: "Company Engineering Blogs"),
    FeedSource(name: "Stripe Blog", url: "https://stripe.com/blog/feed.rss", domain: "stripe.com", defaultEnabled: false, category: "Company Engineering Blogs"),

    // MARK: - Security
    FeedSource(name: "Krebs on Security", url: "https://krebsonsecurity.com/feed/", domain: "krebsonsecurity.com", defaultEnabled: false, category: "Security"),
    FeedSource(name: "Schneier on Security", url: "https://www.schneier.com/feed/atom/", domain: "schneier.com", defaultEnabled: false, category: "Security"),
    FeedSource(name: "The Hacker News", url: "https://feeds.feedburner.com/TheHackersNews", domain: "thehackernews.com", defaultEnabled: false, category: "Security"),

    // MARK: - AI & Research
    FeedSource(name: "OpenAI News", url: "https://openai.com/news/rss.xml", domain: "openai.com", defaultEnabled: true, category: "AI & Research"),
    FeedSource(name: "Google Research", url: "https://research.google/blog/rss/", domain: "google.com", defaultEnabled: false, category: "AI & Research"),
    FeedSource(name: "Hugging Face Blog", url: "https://huggingface.co/blog/feed.xml", domain: "huggingface.co", defaultEnabled: false, category: "AI & Research"),
    FeedSource(name: "arXiv AI", url: "https://export.arxiv.org/rss/cs.AI", domain: "arxiv.org", defaultEnabled: false, category: "AI & Research"),
    FeedSource(name: "arXiv ML", url: "https://export.arxiv.org/rss/cs.LG", domain: "arxiv.org", defaultEnabled: false, category: "AI & Research"),
    FeedSource(name: "arXiv HCI", url: "https://export.arxiv.org/rss/cs.HC", domain: "arxiv.org", defaultEnabled: false, category: "AI & Research"),
    FeedSource(name: "arXiv Security", url: "https://export.arxiv.org/rss/cs.CR", domain: "arxiv.org", defaultEnabled: false, category: "AI & Research"),

    // MARK: - Science
    FeedSource(name: "Science Magazine", url: "https://www.science.org/rss/news_current.xml", domain: "science.org", defaultEnabled: false, category: "Science"),
    FeedSource(name: "Nature News", url: "http://feeds.nature.com/nature/rss/current", domain: "nature.com", defaultEnabled: false, category: "Science"),
    FeedSource(name: "New Scientist", url: "https://www.newscientist.com/feed/home/?cmpid=RSS%7CNSNS-Home", domain: "newscientist.com", defaultEnabled: false, category: "Science"),
    FeedSource(name: "Popular Science", url: "https://www.popsci.com/arcio/rss/", domain: "popsci.com", defaultEnabled: false, category: "Science"),
    FeedSource(name: "Science Daily", url: "https://www.sciencedaily.com/rss/", domain: "sciencedaily.com", defaultEnabled: false, category: "Science"),
    FeedSource(name: "SciTechDaily", url: "https://scitechdaily.com/feed/", domain: "scitechdaily.com", defaultEnabled: false, category: "Science"),
    FeedSource(name: "ZME Science", url: "https://www.zmescience.com/feed/", domain: "zmescience.com", defaultEnabled: false, category: "Science"),
    FeedSource(name: "Impact Science", url: "https://www.impact.science/blog/feed/", domain: "impact.science", defaultEnabled: false, category: "Science"),
    FeedSource(name: "Scientific Inquirer", url: "https://scientificinquirer.com/feed/", domain: "scientificinquirer.com", defaultEnabled: false, category: "Science"),
    FeedSource(name: "NASA Breaking News", url: "https://www.nasa.gov/rss/dyn/breaking_news.rss", domain: "nasa.gov", defaultEnabled: false, category: "Science"),

    // MARK: - Sports
    FeedSource(name: "BBC Sport", url: "https://feeds.bbci.co.uk/sport/rss.xml", domain: "bbc.co.uk", defaultEnabled: false, category: "Sports"),
    FeedSource(name: "ESPN", url: "https://www.espn.com/espn/rss/news", domain: "espn.com", defaultEnabled: false, category: "Sports"),
    FeedSource(name: "Fox Sports", url: "https://api.foxsports.com/v2/content/optimized-rss?partnerKey=MB0Wehpmuj2lUhuRhQaafhBjAJqaPU244mlTDK1i&size=30", domain: "foxsports.com", defaultEnabled: false, category: "Sports"),
    FeedSource(name: "CBS Sports", url: "https://www.cbssports.com/rss/headlines/", domain: "cbssports.com", defaultEnabled: false, category: "Sports"),
    FeedSource(name: "LA Times Sports", url: "https://www.latimes.com/sports.rss", domain: "latimes.com", defaultEnabled: false, category: "Sports"),
    FeedSource(name: "Boxing News", url: "https://boxingnewsonline.net/feed/", domain: "boxingnewsonline.net", defaultEnabled: false, category: "Sports"),
    FeedSource(name: "Sydney Morning Herald Sport", url: "https://www.smh.com.au/rss/sport.xml", domain: "smh.com.au", defaultEnabled: false, category: "Sports"),
    FeedSource(name: "Essentially Sports", url: "https://www.essentiallysports.com/feed/", domain: "essentiallysports.com", defaultEnabled: false, category: "Sports"),

    // MARK: - Entertainment & Pop Culture
    FeedSource(name: "Variety", url: "https://variety.com/feed/", domain: "variety.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "Rolling Stone", url: "https://www.rollingstone.com/music/music-news/feed/", domain: "rollingstone.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "Billboard", url: "https://www.billboard.com/feed/", domain: "billboard.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "Deadline", url: "https://deadline.com/feed/", domain: "deadline.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "IndieWire", url: "https://www.indiewire.com/feed/", domain: "indiewire.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "E! Online", url: "https://www.eonline.com/syndication/feeds/rssfeeds/topstories", domain: "eonline.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "The Shade Room", url: "https://theshaderoom.com/feed/", domain: "theshaderoom.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "Celebrity Insider", url: "https://celebrityinsider.org/feed/", domain: "celebrityinsider.org", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "Hollywood Life", url: "https://hollywoodlife.com/feed/", domain: "hollywoodlife.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),
    FeedSource(name: "Cirrkus", url: "https://cirrkus.com/feed/", domain: "cirrkus.com", defaultEnabled: false, category: "Entertainment & Pop Culture"),

    // MARK: - Health & Wellness
    FeedSource(name: "NHS News", url: "https://www.england.nhs.uk/feed/", domain: "england.nhs.uk", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "NPR Health", url: "https://feeds.npr.org/1128/rss.xml", domain: "npr.org", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "MyFitnessPal Blog", url: "https://blog.myfitnesspal.com/feed/", domain: "myfitnesspal.com", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "Running on Real Food", url: "https://runningonrealfood.com/feed/", domain: "runningonrealfood.com", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "Wellness Impact", url: "https://www.wellnessimpact.org/feed/", domain: "wellnessimpact.org", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "Mindful Momma", url: "https://mindfulmomma.com/feed/", domain: "mindfulmomma.com", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "Love Sweat Fitness", url: "https://lovesweatfitness.com/blogs/news.atom", domain: "lovesweatfitness.com", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "Mark's Daily Apple", url: "https://feeds2.feedburner.com/MarksDailyApple/", domain: "marksdailyapple.com", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "Yoga with Adriene", url: "https://yogawithadriene.com/blog/feed/", domain: "yogawithadriene.com", defaultEnabled: false, category: "Health & Wellness"),
    FeedSource(name: "Mellowed", url: "https://mellowed.com/category/health-wellness/feed/", domain: "mellowed.com", defaultEnabled: false, category: "Health & Wellness"),

    // MARK: - Travel & Lifestyle
    FeedSource(name: "Conde Nast Traveler", url: "https://www.cntraveler.com/feed/rss", domain: "cntraveler.com", defaultEnabled: false, category: "Travel & Lifestyle"),
    FeedSource(name: "Adventure Journal", url: "https://www.adventure-journal.com/feed/", domain: "adventure-journal.com", defaultEnabled: false, category: "Travel & Lifestyle"),
    FeedSource(name: "Nomadic Matt", url: "https://www.nomadicmatt.com/feed/", domain: "nomadicmatt.com", defaultEnabled: false, category: "Travel & Lifestyle"),
    FeedSource(name: "Two Monkeys Travel", url: "https://twomonkeystravelgroup.com/feed/", domain: "twomonkeystravelgroup.com", defaultEnabled: false, category: "Travel & Lifestyle"),
    FeedSource(name: "The Nomad Experiment", url: "https://www.thenomadexperiment.com/feed/", domain: "thenomadexperiment.com", defaultEnabled: false, category: "Travel & Lifestyle"),
    FeedSource(name: "Flight Mate", url: "https://flightmateza.co.za/feed/", domain: "flightmateza.co.za", defaultEnabled: false, category: "Travel & Lifestyle"),
    FeedSource(name: "Travel to Blank", url: "https://traveltoblank.com/feed/", domain: "traveltoblank.com", defaultEnabled: false, category: "Travel & Lifestyle"),
    FeedSource(name: "Rogue Trippers", url: "https://roguetrippers.com/feed/", domain: "roguetrippers.com", defaultEnabled: false, category: "Travel & Lifestyle"),

    // MARK: - Design, Hobbies & Special Interest
    FeedSource(name: "Nielsen Norman Group", url: "https://www.nngroup.com/feed/rss/", domain: "nngroup.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Inside Intercom", url: "https://www.intercom.com/blog/feed/", domain: "intercom.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Stratechery", url: "https://stratechery.com/feed/", domain: "stratechery.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Benedict Evans", url: "https://www.ben-evans.com/benedictevans?format=rss", domain: "ben-evans.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Vogue", url: "https://www.vogue.com/feed/rss", domain: "vogue.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Elle", url: "https://www.elle.com/rss/all.xml/", domain: "elle.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Chess.com News", url: "https://www.chess.com/rss/news", domain: "chess.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "PetaPixel", url: "https://petapixel.com/feed/", domain: "petapixel.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Artists Network", url: "https://www.artistsnetwork.com/feed/", domain: "artistsnetwork.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),
    FeedSource(name: "Whitelines Snowboarding", url: "https://whitelines.com/feed", domain: "whitelines.com", defaultEnabled: false, category: "Design, Hobbies & Special Interest"),

    // MARK: - Tech Specifics & Company News
    FeedSource(name: "BBC Business", url: "https://feeds.bbci.co.uk/news/business/rss.xml", domain: "bbc.co.uk", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "BBC Technology", url: "https://feeds.bbci.co.uk/news/technology/rss.xml", domain: "bbc.co.uk", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "Guardian Technology", url: "https://www.theguardian.com/uk/technology/rss", domain: "theguardian.com", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "Guardian Business", url: "https://www.theguardian.com/uk/business/rss", domain: "theguardian.com", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "NPR Technology", url: "https://feeds.npr.org/1019/rss.xml", domain: "npr.org", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "NPR Planet Money", url: "https://feeds.npr.org/510289/podcast.xml", domain: "npr.org", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "Apple Newsroom", url: "https://www.apple.com/newsroom/rss-feed.rss", domain: "apple.com", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "Microsoft Blog", url: "https://blogs.microsoft.com/feed/", domain: "microsoft.com", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "Google Blog", url: "https://blog.google/rss/", domain: "google.com", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "Mozilla Blog", url: "https://blog.mozilla.org/feed/", domain: "mozilla.org", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "Stack Overflow Blog", url: "https://stackoverflow.blog/feed/", domain: "stackoverflow.blog", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "JetBrains Blog", url: "https://blog.jetbrains.com/feed/", domain: "jetbrains.com", defaultEnabled: false, category: "Tech Specifics & Company News"),
    FeedSource(name: "The Information", url: "https://www.theinformation.com/feed", domain: "theinformation.com", defaultEnabled: false, category: "Tech Specifics & Company News")
]
