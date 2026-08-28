using Epp.Otp;
using Epp.Otp.Providers;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services.AddHttpClient();
builder.Services.AddSingleton<IEnv, ProcessEnv>();
builder.Services.AddSingleton<ISecretResolver, SecretResolver>();
builder.Services.AddSingleton<TokenValidator>();
builder.Services.AddSingleton<IJweKeyProvider, EnvJweKeyProvider>();
builder.Services.AddSingleton<JweDecryptor>();

// Provider adapters — add one line to onboard a provider.
builder.Services.AddSingleton<IProviderAdapter, InfobipProvider>();
builder.Services.AddSingleton<IProviderAdapter, TelesignProvider>();
builder.Services.AddSingleton<IProviderAdapter, SopranoProvider>();
builder.Services.AddSingleton<IProviderAdapter, SinchProvider>();

builder.Services.AddSingleton<ProviderRegistry>();
builder.Services.AddSingleton<DispatchEngine>();

builder.Build().Run();
