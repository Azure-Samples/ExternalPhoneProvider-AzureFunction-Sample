using Epp.Otp;
using Epp.Otp.Providers;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// Application events use selected metadata; provider URLs must not appear in factory logs.
builder.Logging.AddFilter("System.Net.Http.HttpClient." + SendOtp.ProviderHttpClientName, LogLevel.None);
builder.Services.AddHttpClient(SendOtp.ProviderHttpClientName)
	.ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
builder.Services.AddSingleton<IEnv, ProcessEnv>();
builder.Services.AddSingleton<ISecretResolver, SecretResolver>();
builder.Services.AddSingleton<JweDecryptor>();
builder.Services.AddSingleton<PhoneProviderBase, InfobipProvider>();
builder.Services.AddSingleton<PhoneProviderBase, TelesignProvider>();
builder.Services.AddSingleton<PhoneProviderBase, SopranoProvider>();
builder.Services.AddSingleton<PhoneProviderBase, SinchProvider>();

builder.Services.AddSingleton<CredentialTokenService>();
builder.Services.AddHostedService(services => services.GetRequiredService<CredentialTokenService>());
builder.Services.AddSingleton<SendOtp>();

builder.Build().Run();
