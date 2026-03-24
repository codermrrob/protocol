module oclp::oclp_zklogin {
    use sui::zklogin_verified_issuer::{Self};

    public fun create_verified_issuer(
        address_seed: u256,
        issuer: std::string::String,
        ctx: &mut sui::tx_context::TxContext
    ) {
        zklogin_verified_issuer::verify_zklogin_issuer(address_seed, issuer, ctx);
    }
}
