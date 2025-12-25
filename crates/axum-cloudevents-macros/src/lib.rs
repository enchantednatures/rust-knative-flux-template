use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, Data, DeriveInput, Meta};

#[proc_macro_derive(CloudEventTagged, attributes(cloud_event_prefix, cloud_event_type))]
pub fn derive_cloud_event_tagged(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;

    let enum_data = match &input.data {
        Data::Enum(e) => &e.variants,
        _ => panic!("CloudEventTagged can only be derived for enums"),
    };

    let mut prefix = String::new();

    for attr in &input.attrs {
        if attr.path().is_ident("cloud_event_prefix") {
            if let Meta::NameValue(nv) = &attr.meta {
                if let syn::Expr::Lit(expr_lit) = &nv.value {
                    if let syn::Lit::Str(s) = &expr_lit.lit {
                        prefix = s.value();
                    }
                }
            }
        }
    }

    let mut variant_match_arms = Vec::new();
    let mut variant_types = Vec::new();

    for variant in enum_data {
        let variant_name = &variant.ident;
        let mut event_type = None;

        for attr in &variant.attrs {
            if attr.path().is_ident("cloud_event_type") {
                if let Meta::NameValue(nv) = &attr.meta {
                    if let syn::Expr::Lit(expr_lit) = &nv.value {
                        if let syn::Lit::Str(s) = &expr_lit.lit {
                            event_type = Some(s.value());
                        }
                    }
                }
            }
        }

        let event_type = event_type
            .unwrap_or_else(|| panic!("Variant {} missing #[cloud_event_type(\"...\")]", variant_name));

        variant_types.push(variant_name.clone());

        variant_match_arms.push(quote! {
            #event_type => {
                let payload = serde_json::from_value(data)
                    .map_err(|e| e.to_string())?;
                Ok(Self::#variant_name(payload))
            }
        });
    }

    let prefix_str = prefix.as_str();

    let expanded = quote! {
        impl #name {
            pub fn from_cloud_event_parts(
                event_type: &str,
                data: serde_json::Value,
            ) -> Result<Self, String> {
                let suffix = event_type
                    .strip_prefix(#prefix_str)
                    .and_then(|s| s.strip_prefix('.'))
                    .unwrap_or(event_type);

                match suffix {
                    #(#variant_match_arms)*
                    _ => Err(format!("Unknown event type: {}", event_type))
                }
            }
        }
    };

    TokenStream::from(expanded)
}
