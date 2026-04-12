# To Deploy run this on the server. Be very careful

```bash
chmod +x deploy.sh
./deploy.sh
```

# To fresh build flutter app with fresh dependencies install run
```bash
flutter clean                                               
flutter pub get                                                      
flutter run -d windows
```

# To just build the flutter app(Windows) run

```bash                                             
flutter pub get                                                      
flutter run -d windows
```                         

# To build an executable to test in another computer without installation run
```bash
flutter build windows 
```