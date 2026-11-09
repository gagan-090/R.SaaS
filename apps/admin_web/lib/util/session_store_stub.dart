/// Android / iOS / Windows (and tests): no stored session; ApiClient keeps tokens in memory while the app runs.
String? readSession() => null;
void writeSession(String? value) {}
