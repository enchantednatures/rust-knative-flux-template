use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, Data, DeriveInput, Expr, ExprLit, Lit, Meta};

/// Read a `#[attr = "value"]` or `#[attr("value")]` string attribute.
fn string_attr(attrs: &[syn::Attribute], ident: &str) -> Option<String> {
    attrs.iter().find_map(|attr| {
        if !attr.path().is_ident(ident) {
            return None;
        }
        match &attr.meta {
            Meta::NameValue(nv) => match &nv.value {
                Expr::Lit(ExprLit {
                    lit: Lit::Str(s), ..
                }) => Some(s.value()),
                _ => None,
            },
            Meta::List(list) => list.parse_args::<syn::LitStr>().ok().map(|s| s.value()),
            Meta::Path(_) => None,
        }
    })
}

#[proc_macro_derive(CloudEventTagged, attributes(cloud_event_prefix, cloud_event_type))]
pub fn derive_cloud_event_tagged(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;

    let enum_data = match &input.data {
        Data::Enum(e) => &e.variants,
        _ => panic!("CloudEventTagged can only be derived for enums"),
    };

    let prefix = string_attr(&input.attrs, "cloud_event_prefix").unwrap_or_default();

    let mut variant_match_arms = Vec::new();
    let mut variant_types = Vec::new();

    for variant in enum_data {
        let variant_name = &variant.ident;

        let event_type = string_attr(&variant.attrs, "cloud_event_type").unwrap_or_else(|| {
            panic!(
                "Variant {} missing #[cloud_event_type(\"...\")]",
                variant_name
            )
        });

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
