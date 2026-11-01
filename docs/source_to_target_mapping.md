# Source-to-Target Mapping

This page shows where every Gold column comes from, and what is done to it on the way.

## The path of each file

| CSV file | Landing | Source | Bronze | Silver | Gold |
|---|---|---|---|---|---|
| `data/crm/cust_info.csv` | `landing.crm_cust_info` | `source.crm_cust_info` (CDC) | `bronze.crm_cust_info` | `silver.crm_cust_info` | `gold.dim_customers` |
| `data/crm/prd_info.csv` | `landing.crm_prd_info` | `source.crm_prd_info` (CDC) | `bronze.crm_prd_info` | `silver.crm_prd_info` | `gold.dim_products` |
| `data/crm/sales_details.csv` | `landing.crm_sales_details` | `source.crm_sales_details` (CDC) | `bronze.crm_sales_details` | `silver.crm_sales_details` | `gold.fact_sales` |
| `data/erp/cust_az12.csv` | `landing.erp_cust_az12` | `source.erp_cust_az12` (rowversion) | `bronze.erp_cust_az12` | `silver.erp_cust_az12` | `gold.dim_customers` |
| `data/erp/loc_a101.csv` | `landing.erp_loc_a101` | `source.erp_loc_a101` (rowversion) | `bronze.erp_loc_a101` | `silver.erp_loc_a101` | `gold.dim_customers` |
| `data/erp/px_cat_g1v2.csv` | `landing.erp_px_cat_g1v2` | `source.erp_px_cat_g1v2` (full) | `bronze.erp_px_cat_g1v2` | `silver.erp_px_cat_g1v2` | `gold.dim_products` |

- **Landing → Source:** values are converted to the right data types. Rows with a missing key, a value that cannot be converted, or a duplicate key are rejected and saved in `silver.rejected_records` (stage INGESTION).
- **Source → Bronze:** columns are copied without any change, plus extra columns that describe the change.

## gold.dim_customers

| Gold column | Comes from | What is done to it |
|---|---|---|
| customer_key | Created by the warehouse | `IDENTITY`: a new number for each version. -1 = Unknown |
| customer_id | `crm_cust_info.cst_id` | Business key, used as is |
| customer_number | `crm_cust_info.cst_key` | Spaces removed, upper case (Type 1) |
| first_name / last_name | `crm_cust_info.cst_firstname` / `cst_lastname` | Spaces removed, empty text becomes NULL (Type 1) |
| country | `erp_loc_a101.cntry`, joined where `REPLACE(cid, '-', '') = cst_key` | `DE` → Germany, `US`/`USA` → United States, `UK`/`GB` → United Kingdom, blank → n/a (**Type 2**: history kept) |
| marital_status | `crm_cust_info.cst_marital_status` | `S` → Single, `M` → Married, anything else → n/a (**Type 2**: history kept) |
| gender | `crm_cust_info.cst_gndr`, or `erp_cust_az12.gen` if missing | The CRM value is used first. The ERP value is used only when the CRM says n/a (Type 1) |
| birthdate | `erp_cust_az12.bdate`, joined on `cid` without the `NAS` prefix | Dates in the future become NULL (Type 1) |
| create_date | `crm_cust_info.cst_create_date` | Used as is (Type 1) |
| effective_date / expiry_date / is_current / is_deleted | Created by the warehouse | Used for SCD Type 2 history |

## gold.dim_products

| Gold column | Comes from | What is done to it |
|---|---|---|
| product_key | Created by the warehouse | `IDENTITY`. -1 = Unknown |
| product_id | `crm_prd_info.prd_id` | The ID of the current version |
| product_number | `crm_prd_info.prd_key` | Characters 7 onwards of the source key (business key) |
| category_id | `crm_prd_info.prd_key` | Characters 1 to 5, with `-` changed to `_` |
| product_name | `crm_prd_info.prd_nm` | Spaces removed |
| category / subcategory / maintenance | `erp_px_cat_g1v2`, joined where `id = category_id` | Spaces removed; maintenance is Yes or No |
| cost | `crm_prd_info.prd_cost` | Empty → 0; negative → rejected |
| product_line | `crm_prd_info.prd_line` | `M` → Mountain, `R` → Road, `S` → Other Sales, `T` → Touring |
| start_date | `crm_prd_info.prd_start_dt` | In the source file the date is written as `dd-mm-yyyy` |
| is_active | Created by the warehouse | 0 when the product has no current version |

Only the current version of each product number (the one with no end date) is loaded. The end dates are worked out in Silver: the end date of a version is the day before the next version of the same product starts.

## gold.fact_sales

| Gold column | Comes from | What is done to it |
|---|---|---|
| sales_key | Created by the warehouse | `IDENTITY` |
| order_number | `sls_ord_num` | Stored directly on the sales row. Together with product_number, it makes each row unique |
| product_number / customer_id | `sls_prd_key` / `sls_cust_id` | Kept so sales that arrive early can be linked later |
| product_key | Looked up in `dim_products` by product_number | -1 if not found; fixed on a later run |
| customer_key | The `dim_customers` version valid on the order date | -1 if not found; fixed on a later run |
| order_date / shipping_date / due_date | `sls_order_dt`, `sls_ship_dt`, `sls_due_dt` (numbers in YYYYMMDD form) | `0`, the wrong length, or an impossible date → NULL |
| order_date_key, shipping_date_key, due_date_key | `gold.dim_date` | YYYYMMDD; -1 when the date is NULL |
| sales_amount | `sls_sales` | quantity × price when the price is valid; otherwise the original value if it is positive |
| quantity | `sls_quantity` | Must be more than 0 |
| price | `sls_price` | Negative → made positive; missing → sales ÷ quantity |
| is_deleted | Silver | 1 when the line was deleted in the source |
