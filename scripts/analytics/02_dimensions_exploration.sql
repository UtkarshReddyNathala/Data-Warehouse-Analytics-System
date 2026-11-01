/*
===============================================================================
Dimensions Exploration
===============================================================================
In short:
    Shows the distinct values in the dimension tables, such as the list of
    countries and product categories.

Purpose:
    - To explore the structure of dimension tables.
	
SQL Functions Used:
    - DISTINCT
    - ORDER BY
===============================================================================
*/

-- Uses the Gold reporting views (current customer attributes, active sales only).
USE DataWarehouse;
GO


-- Retrieve a list of unique countries from which customers originate
SELECT DISTINCT 
    country 
FROM gold.vw_dim_customers
ORDER BY country;

-- Retrieve a list of unique categories, subcategories, and products
SELECT DISTINCT 
    category, 
    subcategory, 
    product_name 
FROM gold.vw_dim_products
ORDER BY category, subcategory, product_name;
