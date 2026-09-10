using Epp.Otp;
using Epp.Otp.Providers;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// The handler summary is sufficient; provider URLs must not appear in factory logs.
builder.Logging.AddFilter("System.Net.Http.HttpClient." + DispatchEngine.ProviderHttpClientName, LogLevel.None);
builder.Services.AddHttpClient(DispatchEngine.ProviderHttpClientName)
	.ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
builder.Services.AddSingleton<IEnv, ProcessEnv>();
builder.Services.AddSingleton<ISecretResolver, SecretResolver>();
builder.Services.AddSingleton<IJweKeyProvider, EnvJweKeyProvider>();
builder.Services.AddSingleton<JweDecryptor>();

builder.Services.AddSingleton<IProviderAdapter, InfobipProvider>();
builder.Services.AddSingleton<IProviderAdapter, TelesignProvider>();
builder.Services.AddSingleton<IProviderAdapter, SopranoProvider>();
builder.Services.AddSingleton<IProviderAdapter, SinchProvider>();

builder.Services.AddSingleton<ProviderRegistry>();
builder.Services.AddSingleton<DispatchEngine>();

builder.Build().Run();
